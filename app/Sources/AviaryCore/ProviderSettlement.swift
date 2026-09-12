import Foundation

/// The provider crossing a canonical action is about to make.
///
/// This is deliberately smaller than a request body.  The context manifest and request body
/// have their own durable identities; an admission pins the provider/model identity and the
/// pricing snapshot used to interpret any report that follows it.
public struct ProviderAdmission: Hashable, Sendable, Codable {
    public enum Purpose: String, Codable, CaseIterable, Hashable, Sendable {
        case normal
        case compaction
    }

    public static let schemaVersion = 1
    public static let maximumIdentityBytes = 256

    public let purpose: Purpose
    public let rates: ProviderUsage.RateSnapshot

    public init(purpose: Purpose, rates: ProviderUsage.RateSnapshot) {
        self.purpose = purpose
        self.rates = rates
    }

    /// The action kind which is permitted to carry this admission.
    public var expectedActionKind: ActionKind {
        purpose == .normal ? .provider : .compactionProvider
    }

    public func validate(kind: ActionKind) throws {
        try ProviderTimelineCodec.validate(rates: rates)
        guard kind == expectedActionKind else {
            throw ProviderSettlementError.purposeActionMismatch
        }
    }

    /// Validate the model identity carried by a context crossing.  Context manifests retain the
    /// model component (the same `ModelSpec.id` that the provider request receives), while
    /// action targets retain the qualified `ModelSpec.qualifiedID`.  Keep those two checks
    /// separate: model IDs are allowed to contain `/`, so splitting a qualified target at an
    /// arbitrary slash would make a valid model ambiguous.
    ///
    /// RateSnapshot identities are bounded at capture time with the same digest rule used below,
    /// so they can still be checked against a longer recorded request identity.
    public func validate(contextModelID: String, targetModel: String? = nil) throws {
        try validate()
        guard Self.boundedIdentity(contextModelID) == rates.modelID else {
            throw ProviderSettlementError.modelIdentityMismatch
        }
        if let targetModel {
            let qualifiedSuffix = "/" + contextModelID
            let rawTargetMatches = targetModel.hasSuffix(qualifiedSuffix)
                && Self.boundedIdentity(
                    String(targetModel.dropLast(qualifiedSuffix.count))) == rates.providerID
            let boundedTargetMatches = targetModel == "\(rates.providerID)/\(rates.modelID)"
            guard rawTargetMatches || boundedTargetMatches else {
                throw ProviderSettlementError.modelIdentityMismatch
            }
        }
    }

    private static func boundedIdentity(_ value: String) -> String {
        guard value.utf8.count > maximumIdentityBytes else { return value }
        return AviarySHA256.hash(data: Data(value.utf8)).description
    }

    public func validate() throws {
        try ProviderTimelineCodec.validate(rates: rates)
    }

    /// The bounded, strict timeline representation.  Token counts are never JSON numbers:
    /// ``JSONValue`` stores numbers as ``Double``, which cannot carry every ``Int`` exactly.
    public var timelineValue: JSONValue {
        .object([
            "schema": .number(Double(Self.schemaVersion)),
            "purpose": .string(purpose.rawValue),
            "rates": ProviderTimelineCodec.rateSnapshotValue(rates),
        ])
    }

    public init(timelineValue: JSONValue) throws {
        let object = try ProviderTimelineCodec.object(
            timelineValue, allowed: ["schema", "purpose", "rates"])
        try ProviderTimelineCodec.schema(object["schema"], expected: Self.schemaVersion)
        guard let purposeRaw = object["purpose"]?.stringValue,
              let purpose = Purpose(rawValue: purposeRaw)
        else { throw ProviderSettlementError.invalidField("purpose") }
        guard let ratesValue = object["rates"] else {
            throw ProviderSettlementError.missingField("rates")
        }
        let rates = try ProviderTimelineCodec.rateSnapshot(ratesValue)
        try ProviderTimelineCodec.validate(rates: rates)
        self.purpose = purpose
        self.rates = rates
    }

    public init(from decoder: Decoder) throws {
        self = try ProviderAdmission(
            timelineValue: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        try timelineValue.encode(to: encoder)
    }
}

    /// The provider's durable settlement observation. A transport failure may settle the action
    /// without a report; a ``finalReport`` is a terminal boundary even when usage is absent.
public struct ProviderSettlement: Hashable, Sendable, Codable {
    public static let schemaVersion = 1

    public let admission: ProviderAdmission
    public let report: ProviderUsage.RawReport?
    public let finality: ProviderUsage.ReportFinality

    public init(
        admission: ProviderAdmission,
        report: ProviderUsage.RawReport?,
        finality: ProviderUsage.ReportFinality
    ) {
        self.admission = admission
        self.report = report
        self.finality = finality
    }

    /// Accounting is always recomputed from the pinned admission rates and the report.  It is
    /// not cached in the timeline payload, so changing an implementation cannot accidentally
    /// make a second, conflicting price authoritative.
    public var accounted: ProviderUsage.AccountedCrossing {
        ProviderUsage.account(report: report, rates: admission.rates)
    }

    public var usage: Usage {
        Usage(finality: finality, accounted: accounted)
    }

    /// Validate the settlement against the action's canonical kind and terminal outcome.
    /// Callers still own the once-only action transition; this value intentionally carries no
    /// lifetime action ID set.
    public func validate(
        admission expectedAdmission: ProviderAdmission,
        kind: ActionKind,
        state: ActionExecutionState
    ) throws {
        try validateSelf()
        guard admission == expectedAdmission else {
            throw ProviderSettlementError.admissionMismatch
        }
        try admission.validate(kind: kind)
        guard state.isTerminal else {
            throw ProviderSettlementError.nonTerminalOutcome
        }
        if state == .succeeded {
            guard finality == .finalReport else {
                throw ProviderSettlementError.successRequiresFinalReport
            }
        }
    }

    fileprivate func validateSelf() throws {
        try admission.validate()
        try ProviderTimelineCodec.validate(report: report)
    }

    /// Strict timeline representation.  The report is omitted when absent; a present report is
    /// an object with canonical decimal count strings and an exact provider accounting mode.
    public var timelineValue: JSONValue {
        var value: [String: JSONValue] = [
            "schema": .number(Double(Self.schemaVersion)),
            "admission": admission.timelineValue,
            "finality": .string(finality.rawValue),
        ]
        if let report {
            value["report"] = ProviderTimelineCodec.rawReportValue(report)
        }
        return .object(value)
    }

    public init(timelineValue: JSONValue) throws {
        let object = try ProviderTimelineCodec.object(
            timelineValue, allowed: ["schema", "admission", "report", "finality"])
        try ProviderTimelineCodec.schema(object["schema"], expected: Self.schemaVersion)
        guard let admissionValue = object["admission"] else {
            throw ProviderSettlementError.missingField("admission")
        }
        let admission = try ProviderAdmission(timelineValue: admissionValue)
        guard let finalityRaw = object["finality"]?.stringValue,
              let finality = ProviderUsage.ReportFinality(rawValue: finalityRaw)
        else { throw ProviderSettlementError.invalidField("finality") }
        let report: ProviderUsage.RawReport?
        if let reportValue = object["report"] {
            report = try ProviderTimelineCodec.rawReport(reportValue)
        } else {
            report = nil
        }
        self.admission = admission
        self.report = report
        self.finality = finality
        try validateSelf()
    }

    public init(from decoder: Decoder) throws {
        self = try ProviderSettlement(timelineValue: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try validateSelf()
        try timelineValue.encode(to: encoder)
    }
}

/// Aggregate provider accounting for one Work projection.  The aggregate deliberately stores
/// no action IDs: action identity and once-only replay belong to the canonical reducer.  This
/// value only enforces the count transition (a settlement cannot exceed admitted starts) and
/// keeps exact values separate from unresolved dimensions and known lower bounds.
public struct ProviderUsageAggregate: Hashable, Sendable, Codable {
    public static let schemaVersion = 1
    /// This is an integer-domain guard, not a product-level usage quota.
    public static let maximumCrossings = Int.max

    public struct UnresolvedCounts: Hashable, Sendable, Codable {
        public var total: Int
        public var breakdown: Int
        public var cost: Int

        public init(total: Int = 0, breakdown: Int = 0, cost: Int = 0) {
            self.total = total
            self.breakdown = breakdown
            self.cost = cost
        }
    }

    public struct KnownFloors: Hashable, Sendable, Codable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheWriteTokens: Int
        public var totalTokens: Int
        public var cost: Double

        public init(
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cacheReadTokens: Int = 0,
            cacheWriteTokens: Int = 0,
            totalTokens: Int = 0,
            cost: Double = 0
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.totalTokens = totalTokens
            self.cost = cost
        }
    }

    public struct OverflowFlags: Hashable, Sendable, Codable {
        public var tokenCounts: Bool
        public var cost: Bool

        public init(tokenCounts: Bool = false, cost: Bool = false) {
            self.tokenCounts = tokenCounts
            self.cost = cost
        }
    }

    public private(set) var started: Int
    public private(set) var settled: Int
    public private(set) var unresolved: UnresolvedCounts
    public private(set) var knownFloors: KnownFloors
    public private(set) var overflow: OverflowFlags

    public init(
        started: Int = 0,
        settled: Int = 0,
        unresolved: UnresolvedCounts = UnresolvedCounts(),
        knownFloors: KnownFloors = KnownFloors(),
        overflow: OverflowFlags = OverflowFlags()
    ) {
        self.started = started
        self.settled = settled
        self.unresolved = unresolved
        self.knownFloors = knownFloors
        self.overflow = overflow
    }

    public var unresolvedTotal: Int { unresolved.total }
    public var unresolvedBreakdown: Int { unresolved.breakdown }
    public var unresolvedCost: Int { unresolved.cost }
    public var knownTokenFloor: Int { knownFloors.totalTokens }
    public var knownCostFloor: Double { knownFloors.cost }
    public var tokenOverflow: Bool { overflow.tokenCounts }
    public var costOverflow: Bool { overflow.cost }

    public mutating func recordStarted() throws {
        var candidate = self
        guard candidate.started < Self.maximumCrossings else {
            throw ProviderSettlementError.aggregateOverflow
        }
        candidate.started += 1
        try candidate.addUnresolved(\.total)
        try candidate.addUnresolved(\.breakdown)
        try candidate.addUnresolved(\.cost)
        try candidate.validate()
        self = candidate
    }

    public mutating func recordSettlement(_ settlement: ProviderSettlement) throws {
        var candidate = self
        try candidate.applySettlement(settlement)
        try candidate.validate()
        self = candidate
    }

    private mutating func applySettlement(_ settlement: ProviderSettlement) throws {
        try settlement.validateSelf()
        guard settled < started else {
            throw ProviderSettlementError.settlementWithoutStart
        }
        let accounted = settlement.accounted
        let usage = settlement.usage
        settled += 1
        let tokenOverflowBefore = overflow.tokenCounts
        let costOverflowBefore = overflow.cost
        try addTokenFloor(usage.input, keyPath: \.inputTokens)
        try addTokenFloor(usage.output, keyPath: \.outputTokens)
        try addTokenFloor(usage.cacheRead, keyPath: \.cacheReadTokens)
        try addTokenFloor(usage.cacheWrite, keyPath: \.cacheWriteTokens)
        try addTokenFloor(usage.totalTokens, keyPath: \.totalTokens)
        // Individual fields can fit in Int while their disjoint lower-bound sum does not.
        // Preserve that uncertainty before the exact-final cleanup below; otherwise a valid
        // saturated observation could clear unresolved markers and fail as an invalid aggregate.
        if tokenComponentFloorOverflowed { overflow.tokenCounts = true }
        addCost(accounted.price.knownTotal)

        let exactFinal = settlement.finality == .finalReport
        if exactFinal && usage.completeness.tokenTotal == .complete
            && !tokenOverflowBefore && !overflow.tokenCounts {
            try removeUnresolved(\.total)
        }
        if exactFinal && usage.completeness.breakdown == .complete
            && !tokenOverflowBefore && !overflow.tokenCounts {
            try removeUnresolved(\.breakdown)
        }
        if exactFinal && usage.completeness.cost == .complete
            && !costOverflowBefore && !overflow.cost {
            try removeUnresolved(\.cost)
        }
    }

    public func validate() throws {
        guard started >= 0, settled >= 0, settled <= started else {
            throw ProviderSettlementError.invalidAggregate
        }
        let outstanding = started - settled
        guard unresolved.total >= 0, unresolved.breakdown >= 0, unresolved.cost >= 0,
              unresolved.total >= outstanding, unresolved.breakdown >= outstanding,
              unresolved.cost >= outstanding, unresolved.total <= started,
              unresolved.breakdown <= started, unresolved.cost <= started else {
            throw ProviderSettlementError.invalidAggregate
        }
        let values = [
            knownFloors.inputTokens, knownFloors.outputTokens,
            knownFloors.cacheReadTokens, knownFloors.cacheWriteTokens,
            knownFloors.totalTokens,
        ]
        guard values.allSatisfy({ $0 >= 0 }), knownFloors.cost.isFinite,
              knownFloors.cost >= 0 else {
            throw ProviderSettlementError.invalidAggregate
        }
        if settled == 0 {
            guard knownFloors == KnownFloors(), !overflow.tokenCounts, !overflow.cost else {
                throw ProviderSettlementError.invalidAggregate
            }
        }
        var componentFloor = 0
        var componentFloorOverflowed = false
        for value in [
            knownFloors.inputTokens, knownFloors.outputTokens,
            knownFloors.cacheReadTokens, knownFloors.cacheWriteTokens,
        ] {
            let (next, didOverflow) = componentFloor.addingReportingOverflow(value)
            if didOverflow {
                componentFloorOverflowed = true
                break
            }
            componentFloor = next
        }
        if componentFloorOverflowed {
            // A saturated component sum is not an exact total.  Preserve an outstanding
            // uncertainty marker and the token-overflow bit rather than accepting a forged
            // zero/partial total as complete evidence.
            guard overflow.tokenCounts,
                  unresolved.total > 0 || unresolved.breakdown > 0 else {
                throw ProviderSettlementError.invalidAggregate
            }
        } else if unresolved.total == 0 {
            guard knownFloors.totalTokens >= componentFloor else {
                throw ProviderSettlementError.invalidAggregate
            }
            if unresolved.breakdown == 0 {
                guard knownFloors.totalTokens == componentFloor else {
                    throw ProviderSettlementError.invalidAggregate
                }
            }
        }
        if overflow.tokenCounts {
            guard unresolved.total > 0 || unresolved.breakdown > 0 else {
                throw ProviderSettlementError.invalidAggregate
            }
        }
        if overflow.cost {
            guard unresolved.cost > 0 else { throw ProviderSettlementError.invalidAggregate }
        }
    }

    public var timelineValue: JSONValue {
        .object([
            "schema": .number(Double(Self.schemaVersion)),
            "started": ProviderTimelineCodec.decimal(started),
            "settled": ProviderTimelineCodec.decimal(settled),
            "unresolved": .object([
                "total": ProviderTimelineCodec.decimal(unresolved.total),
                "breakdown": ProviderTimelineCodec.decimal(unresolved.breakdown),
                "cost": ProviderTimelineCodec.decimal(unresolved.cost),
            ]),
            "known_floors": .object([
                "input_tokens": ProviderTimelineCodec.decimal(knownFloors.inputTokens),
                "output_tokens": ProviderTimelineCodec.decimal(knownFloors.outputTokens),
                "cache_read_tokens": ProviderTimelineCodec.decimal(knownFloors.cacheReadTokens),
                "cache_write_tokens": ProviderTimelineCodec.decimal(knownFloors.cacheWriteTokens),
                "total_tokens": ProviderTimelineCodec.decimal(knownFloors.totalTokens),
                "cost_bits": ProviderTimelineCodec.doubleBits(knownFloors.cost),
            ]),
            "overflow": .object([
                "token_counts": .bool(overflow.tokenCounts),
                "cost": .bool(overflow.cost),
            ]),
        ])
    }

    public init(timelineValue: JSONValue) throws {
        let object = try ProviderTimelineCodec.object(timelineValue, allowed: [
            "schema", "started", "settled", "unresolved", "known_floors", "overflow",
        ])
        try ProviderTimelineCodec.schema(object["schema"], expected: Self.schemaVersion)
        let started = try ProviderTimelineCodec.integer(object["started"], field: "started")
        let settled = try ProviderTimelineCodec.integer(object["settled"], field: "settled")
        let unresolvedValue = try ProviderTimelineCodec.requiredObject(
            object["unresolved"], field: "unresolved")
        try ProviderTimelineCodec.requireKeys(
            unresolvedValue, allowed: ["total", "breakdown", "cost"])
        let unresolved = UnresolvedCounts(
            total: try ProviderTimelineCodec.integer(unresolvedValue["total"], field: "unresolved.total"),
            breakdown: try ProviderTimelineCodec.integer(
                unresolvedValue["breakdown"], field: "unresolved.breakdown"),
            cost: try ProviderTimelineCodec.integer(unresolvedValue["cost"], field: "unresolved.cost"))

        let floorsValue = try ProviderTimelineCodec.requiredObject(
            object["known_floors"], field: "known_floors")
        try ProviderTimelineCodec.requireKeys(floorsValue, allowed: [
            "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
            "total_tokens", "cost_bits",
        ])
        let knownFloors = KnownFloors(
            inputTokens: try ProviderTimelineCodec.integer(
                floorsValue["input_tokens"], field: "known_floors.input_tokens"),
            outputTokens: try ProviderTimelineCodec.integer(
                floorsValue["output_tokens"], field: "known_floors.output_tokens"),
            cacheReadTokens: try ProviderTimelineCodec.integer(
                floorsValue["cache_read_tokens"], field: "known_floors.cache_read_tokens"),
            cacheWriteTokens: try ProviderTimelineCodec.integer(
                floorsValue["cache_write_tokens"], field: "known_floors.cache_write_tokens"),
            totalTokens: try ProviderTimelineCodec.integer(
                floorsValue["total_tokens"], field: "known_floors.total_tokens"),
            cost: try ProviderTimelineCodec.double(floorsValue["cost_bits"], field: "cost_bits"))

        let overflowValue = try ProviderTimelineCodec.requiredObject(
            object["overflow"], field: "overflow")
        try ProviderTimelineCodec.requireKeys(overflowValue, allowed: ["token_counts", "cost"])
        let tokenOverflow = try ProviderTimelineCodec.boolean(
            overflowValue["token_counts"], field: "overflow.token_counts")
        let costOverflow = try ProviderTimelineCodec.boolean(
            overflowValue["cost"], field: "overflow.cost")
        self.init(
            started: started, settled: settled, unresolved: unresolved,
            knownFloors: knownFloors,
            overflow: OverflowFlags(tokenCounts: tokenOverflow, cost: costOverflow))
        try validate()
    }

    public init(from decoder: Decoder) throws {
        self = try ProviderUsageAggregate(timelineValue: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        try timelineValue.encode(to: encoder)
    }

    private mutating func addTokenFloor(
        _ value: Int, keyPath: WritableKeyPath<KnownFloors, Int>
    ) throws {
        guard value >= 0 else { throw ProviderSettlementError.invalidAggregate }
        let current = knownFloors[keyPath: keyPath]
        let (next, overflowed) = current.addingReportingOverflow(value)
        if overflowed { overflow.tokenCounts = true; knownFloors[keyPath: keyPath] = Int.max }
        else { knownFloors[keyPath: keyPath] = next }
    }

    private mutating func addUnresolved(
        _ keyPath: WritableKeyPath<UnresolvedCounts, Int>
    ) throws {
        let current = unresolved[keyPath: keyPath]
        let (next, overflowed) = current.addingReportingOverflow(1)
        guard !overflowed else { throw ProviderSettlementError.aggregateOverflow }
        unresolved[keyPath: keyPath] = next
    }

    private mutating func removeUnresolved(
        _ keyPath: WritableKeyPath<UnresolvedCounts, Int>
    ) throws {
        guard unresolved[keyPath: keyPath] > 0 else {
            throw ProviderSettlementError.invalidAggregate
        }
        unresolved[keyPath: keyPath] -= 1
    }

    private var tokenComponentFloorOverflowed: Bool {
        var total = 0
        for value in [
            knownFloors.inputTokens, knownFloors.outputTokens,
            knownFloors.cacheReadTokens, knownFloors.cacheWriteTokens,
        ] {
            let (next, didOverflow) = total.addingReportingOverflow(value)
            if didOverflow { return true }
            total = next
        }
        return false
    }

    private mutating func addCost(_ value: Double) {
        guard value.isFinite, value >= 0 else {
            overflow.cost = true
            return
        }
        let next = knownFloors.cost + value
        if !next.isFinite { overflow.cost = true }
        else { knownFloors.cost = next }
    }
}

extension ProviderUsageAggregate.UnresolvedCounts {
    fileprivate var timelineValue: JSONValue {
        .object([
            "total": ProviderTimelineCodec.decimal(total),
            "breakdown": ProviderTimelineCodec.decimal(breakdown),
            "cost": ProviderTimelineCodec.decimal(cost),
        ])
    }

    fileprivate init(timelineValue: JSONValue) throws {
        let object = try ProviderTimelineCodec.object(
            timelineValue, allowed: ["total", "breakdown", "cost"])
        self.init(
            total: try ProviderTimelineCodec.integer(object["total"], field: "unresolved.total"),
            breakdown: try ProviderTimelineCodec.integer(
                object["breakdown"], field: "unresolved.breakdown"),
            cost: try ProviderTimelineCodec.integer(object["cost"], field: "unresolved.cost"))
    }

    public init(from decoder: Decoder) throws {
        try self.init(timelineValue: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try timelineValue.encode(to: encoder)
    }
}

extension ProviderUsageAggregate.KnownFloors {
    fileprivate var timelineValue: JSONValue {
        .object([
            "input_tokens": ProviderTimelineCodec.decimal(inputTokens),
            "output_tokens": ProviderTimelineCodec.decimal(outputTokens),
            "cache_read_tokens": ProviderTimelineCodec.decimal(cacheReadTokens),
            "cache_write_tokens": ProviderTimelineCodec.decimal(cacheWriteTokens),
            "total_tokens": ProviderTimelineCodec.decimal(totalTokens),
            "cost_bits": ProviderTimelineCodec.doubleBits(cost),
        ])
    }

    fileprivate init(timelineValue: JSONValue) throws {
        let object = try ProviderTimelineCodec.object(timelineValue, allowed: [
            "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
            "total_tokens", "cost_bits",
        ])
        self.init(
            inputTokens: try ProviderTimelineCodec.integer(
                object["input_tokens"], field: "known_floors.input_tokens"),
            outputTokens: try ProviderTimelineCodec.integer(
                object["output_tokens"], field: "known_floors.output_tokens"),
            cacheReadTokens: try ProviderTimelineCodec.integer(
                object["cache_read_tokens"], field: "known_floors.cache_read_tokens"),
            cacheWriteTokens: try ProviderTimelineCodec.integer(
                object["cache_write_tokens"], field: "known_floors.cache_write_tokens"),
            totalTokens: try ProviderTimelineCodec.integer(
                object["total_tokens"], field: "known_floors.total_tokens"),
            cost: try ProviderTimelineCodec.double(object["cost_bits"], field: "cost_bits"))
    }

    public init(from decoder: Decoder) throws {
        try self.init(timelineValue: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try timelineValue.encode(to: encoder)
    }
}

extension ProviderUsageAggregate.OverflowFlags {
    fileprivate var timelineValue: JSONValue {
        .object(["token_counts": .bool(tokenCounts), "cost": .bool(cost)])
    }

    fileprivate init(timelineValue: JSONValue) throws {
        let object = try ProviderTimelineCodec.object(
            timelineValue, allowed: ["token_counts", "cost"])
        self.init(
            tokenCounts: try ProviderTimelineCodec.boolean(
                object["token_counts"], field: "overflow.token_counts"),
            cost: try ProviderTimelineCodec.boolean(object["cost"], field: "overflow.cost"))
    }

    public init(from decoder: Decoder) throws {
        try self.init(timelineValue: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try timelineValue.encode(to: encoder)
    }
}

public enum ProviderSettlementError: Error, LocalizedError, Equatable, Sendable {
    case missingField(String)
    case unknownField(String)
    case invalidField(String)
    case invalidSchema
    case invalidIdentity
    case invalidDecimal(String)
    case invalidDoubleBits(String)
    case invalidRate
    case purposeActionMismatch
    case modelIdentityMismatch
    case admissionMismatch
    case successRequiresFinalReport
    case nonTerminalOutcome
    case settlementWithoutStart
    case aggregateOverflow
    case invalidAggregate

    public var errorDescription: String? {
        switch self {
        case .missingField: return "Provider settlement is missing a required field."
        case .unknownField: return "Provider settlement contains an unknown field."
        case .invalidField: return "Provider settlement contains an invalid field."
        case .invalidSchema: return "Provider settlement schema is unsupported."
        case .invalidIdentity: return "Provider settlement identity is invalid."
        case .invalidDecimal: return "Provider settlement count encoding is invalid."
        case .invalidDoubleBits: return "Provider settlement double encoding is invalid."
        case .invalidRate: return "Provider settlement contains an invalid rate."
        case .purposeActionMismatch: return "Provider admission purpose does not match action kind."
        case .modelIdentityMismatch: return "Provider crossing model identity does not match admission."
        case .admissionMismatch: return "Provider settlement admission does not match the action."
        case .successRequiresFinalReport: return "A successful provider action needs a final report."
        case .nonTerminalOutcome: return "Provider settlement requires a terminal action outcome."
        case .settlementWithoutStart: return "Provider settlement has no outstanding admission."
        case .aggregateOverflow: return "Provider usage aggregate is bounded."
        case .invalidAggregate: return "Provider usage aggregate is invalid."
        }
    }
}

// MARK: - Existing ProviderUsage integration

extension ProviderUsage.RateSnapshot {
    /// Strict construction seam used by timeline decoding.  Invalid pricing is represented by
    /// ``invalidRates`` with a nil corresponding value; it remains valid evidence, not a zero
    /// price.
    fileprivate init(
        timelineProviderID providerID: String,
        timelineModelID modelID: String,
        inputPerMillion: Double?, outputPerMillion: Double?,
        cacheReadPerMillion: Double?, cacheWritePerMillion: Double?,
        invalidRates: Set<ProviderUsage.PricingCategory>
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.invalidRates = invalidRates
    }
}

// MARK: - Strict timeline codec

private enum ProviderTimelineCodec {
    static let maximumDecimalBytes = 64

    static func object(
        _ value: JSONValue, allowed: Set<String>
    ) throws -> [String: JSONValue] {
        guard let object = value.objectValue else {
            throw ProviderSettlementError.invalidField("object")
        }
        try requireKeys(object, allowed: allowed)
        return object
    }

    static func requiredObject(
        _ value: JSONValue?, field: String
    ) throws -> [String: JSONValue] {
        guard let value else { throw ProviderSettlementError.missingField(field) }
        guard let object = value.objectValue else {
            throw ProviderSettlementError.invalidField(field)
        }
        return object
    }

    static func requireKeys(
        _ object: [String: JSONValue], allowed: Set<String>
    ) throws {
        for key in object.keys where !allowed.contains(key) {
            throw ProviderSettlementError.unknownField(key)
        }
    }

    static func schema(_ value: JSONValue?, expected: Int) throws {
        guard let value, case .number(let number) = value,
              number.isFinite, number.rounded() == number,
              let schema = Int(exactly: number), schema == expected else {
            throw ProviderSettlementError.invalidSchema
        }
    }

    static func boolean(_ value: JSONValue?, field: String) throws -> Bool {
        guard let value, case .bool(let result) = value else {
            throw ProviderSettlementError.invalidField(field)
        }
        return result
    }

    static func validate(rates: ProviderUsage.RateSnapshot) throws {
        guard validIdentity(rates.providerID), validIdentity(rates.modelID) else {
            throw ProviderSettlementError.invalidIdentity
        }
        let values: [(ProviderUsage.PricingCategory, Double?)] = [
            (.input, rates.inputPerMillion), (.output, rates.outputPerMillion),
            (.cacheRead, rates.cacheReadPerMillion), (.cacheWrite, rates.cacheWritePerMillion),
        ]
        for (category, value) in values {
            if let value {
                guard value.isFinite, value >= 0, !rates.invalidRates.contains(category) else {
                    throw ProviderSettlementError.invalidRate
                }
            }
            if rates.invalidRates.contains(category), value != nil {
                throw ProviderSettlementError.invalidRate
            }
        }
    }

    static func validate(report: ProviderUsage.RawReport?) throws {
        guard let report else { return }
        // Raw observations may be negative: ProviderUsage intentionally preserves malformed
        // wire values so accounting can classify them instead of silently changing them to zero.
        // The strict codec still bounds their representation to the native Int domain.
        _ = report
    }

    static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= ProviderAdmission.maximumIdentityBytes
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    static func decimal(_ value: Int) -> JSONValue { .string(String(value)) }

    static func integer(_ value: JSONValue?, field: String) throws -> Int {
        guard let value, case .string(let string) = value,
              string.utf8.count <= maximumDecimalBytes,
              let integer = Int(string), String(integer) == string else {
            throw ProviderSettlementError.invalidDecimal(field)
        }
        return integer
    }

    static func doubleBits(_ value: Double) -> JSONValue {
        let digits = String(value.bitPattern, radix: 16)
        return .string(String(repeating: "0", count: max(0, 16 - digits.count)) + digits)
    }

    static func double(_ value: JSONValue?, field: String) throws -> Double {
        guard let value, case .string(let string) = value,
              string.utf8.count == 16,
              string.unicodeScalars.allSatisfy({
                  (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
              }),
              let bits = UInt64(string, radix: 16) else {
            throw ProviderSettlementError.invalidDoubleBits(field)
        }
        let decoded = Double(bitPattern: bits)
        guard decoded.isFinite, decoded >= 0 else {
            throw ProviderSettlementError.invalidDoubleBits(field)
        }
        return decoded
    }

    static func rateSnapshotValue(_ rates: ProviderUsage.RateSnapshot) -> JSONValue {
        var object: [String: JSONValue] = [
            "schema": .number(1),
            "provider_id": .string(rates.providerID),
            "model_id": .string(rates.modelID),
            "invalid_rates": .array(rates.invalidRates.sorted {
                $0.rawValue < $1.rawValue
            }.map { .string($0.rawValue) }),
        ]
        if let value = rates.inputPerMillion { object["input_bits"] = doubleBits(value) }
        if let value = rates.outputPerMillion { object["output_bits"] = doubleBits(value) }
        if let value = rates.cacheReadPerMillion { object["cache_read_bits"] = doubleBits(value) }
        if let value = rates.cacheWritePerMillion { object["cache_write_bits"] = doubleBits(value) }
        return .object(object)
    }

    static func rateSnapshot(_ value: JSONValue) throws -> ProviderUsage.RateSnapshot {
        let object = try self.object(value, allowed: [
            "schema", "provider_id", "model_id", "input_bits", "output_bits",
            "cache_read_bits", "cache_write_bits", "invalid_rates",
        ])
        try schema(object["schema"], expected: 1)
        guard let providerID = object["provider_id"]?.stringValue,
              let modelID = object["model_id"]?.stringValue,
              validIdentity(providerID), validIdentity(modelID) else {
            throw ProviderSettlementError.invalidIdentity
        }
        guard let invalidValues = object["invalid_rates"]?.arrayValue else {
            throw ProviderSettlementError.missingField("rates.invalid_rates")
        }
        let invalidStrings = invalidValues.compactMap(\.stringValue)
        guard invalidStrings.count == invalidValues.count,
              Set(invalidStrings).count == invalidStrings.count else {
            throw ProviderSettlementError.invalidField("rates.invalid_rates")
        }
        var invalidRates: Set<ProviderUsage.PricingCategory> = []
        for raw in invalidStrings {
            guard let category = ProviderUsage.PricingCategory(rawValue: raw) else {
                throw ProviderSettlementError.invalidField("rates.invalid_rates")
            }
            invalidRates.insert(category)
        }
        let input = try optionalDouble(object["input_bits"], field: "rates.input_bits")
        let output = try optionalDouble(object["output_bits"], field: "rates.output_bits")
        let cacheRead = try optionalDouble(
            object["cache_read_bits"], field: "rates.cache_read_bits")
        let cacheWrite = try optionalDouble(
            object["cache_write_bits"], field: "rates.cache_write_bits")
        let rates = ProviderUsage.RateSnapshot(
            timelineProviderID: providerID, timelineModelID: modelID,
            inputPerMillion: input, outputPerMillion: output,
            cacheReadPerMillion: cacheRead, cacheWritePerMillion: cacheWrite,
            invalidRates: invalidRates)
        try validate(rates: rates)
        return rates
    }

    static func optionalDouble(_ value: JSONValue?, field: String) throws -> Double? {
        guard let value else { return nil }
        return try double(value, field: field)
    }

    static func rawReportValue(_ report: ProviderUsage.RawReport) -> JSONValue {
        var object: [String: JSONValue] = [
            "input_accounting": .string(report.inputAccounting.rawValue),
            "malformed_fields": .array(report.malformedFields.sorted {
                $0.rawValue < $1.rawValue
            }.map { .string($0.rawValue) }),
        ]
        if let value = report.inputTokens { object["input_tokens"] = decimal(value) }
        if let value = report.outputTokens { object["output_tokens"] = decimal(value) }
        if let value = report.cacheReadTokens { object["cache_read_tokens"] = decimal(value) }
        if let value = report.cacheWriteTokens { object["cache_write_tokens"] = decimal(value) }
        if let value = report.reasoningTokens { object["reasoning_tokens"] = decimal(value) }
        if let value = report.reportedTotalTokens { object["reported_total_tokens"] = decimal(value) }
        return .object(object)
    }

    static func rawReport(_ value: JSONValue) throws -> ProviderUsage.RawReport {
        let object = try self.object(value, allowed: [
            "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
            "reasoning_tokens", "reported_total_tokens", "input_accounting", "malformed_fields",
        ])
        guard let accountingRaw = object["input_accounting"]?.stringValue,
              let accounting = ProviderUsageAccounting(rawValue: accountingRaw),
              let malformedValues = object["malformed_fields"]?.arrayValue else {
            throw ProviderSettlementError.invalidField("report")
        }
        let malformedStrings = malformedValues.compactMap(\.stringValue)
        guard malformedStrings.count == malformedValues.count,
              Set(malformedStrings).count == malformedStrings.count else {
            throw ProviderSettlementError.invalidField("report.malformed_fields")
        }
        var malformed: Set<ProviderUsage.Field> = []
        for raw in malformedStrings {
            guard let field = ProviderUsage.Field(rawValue: raw) else {
                throw ProviderSettlementError.invalidField("report.malformed_fields")
            }
            malformed.insert(field)
        }
        return ProviderUsage.RawReport(
            inputTokens: try optionalInteger(object["input_tokens"], field: "report.input_tokens"),
            outputTokens: try optionalInteger(object["output_tokens"], field: "report.output_tokens"),
            cacheReadTokens: try optionalInteger(
                object["cache_read_tokens"], field: "report.cache_read_tokens"),
            cacheWriteTokens: try optionalInteger(
                object["cache_write_tokens"], field: "report.cache_write_tokens"),
            reasoningTokens: try optionalInteger(
                object["reasoning_tokens"], field: "report.reasoning_tokens"),
            reportedTotalTokens: try optionalInteger(
                object["reported_total_tokens"], field: "report.reported_total_tokens"),
            inputAccounting: accounting,
            malformedFields: malformed)
    }

    static func optionalInteger(_ value: JSONValue?, field: String) throws -> Int? {
        guard let value else { return nil }
        return try integer(value, field: field)
    }
}
