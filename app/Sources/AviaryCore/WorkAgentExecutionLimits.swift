import Foundation

/// A cooperative pre-crossing policy for a Work-owned background Agent.
///
/// `nil` means unlimited.  A finite value is an admission threshold, not a provider or
/// invoice guarantee: a provider crossing is postpaid and may report more usage than was known
/// before it began.  The caller must settle that crossing once, then evaluate this policy before
/// admitting another one.  Python effects which bypass a provider crossing are deliberately
/// outside this policy's boundary.
public struct WorkAgentExecutionLimits: Hashable, Sendable, Codable {
    public static let schemaVersion = 1
    public static let maximumDecimalBytes = 64
    public static let unlimited = WorkAgentExecutionLimits(unlimited: ())

    private init(unlimited: Void) {
        maximumTokens = nil
        maximumEstimatedCostUSD = nil
    }

    /// A positive token threshold for this child execution's canonical provider aggregate.
    public let maximumTokens: Int?
    /// A positive USD estimate threshold over the aggregate's known cost floor.  This is an
    /// estimate because provider billing and missing observations are not controlled here.
    public let maximumEstimatedCostUSD: Double?

    public init(
        maximumTokens: Int? = nil,
        maximumEstimatedCostUSD: Double? = nil
    ) throws {
        if let maximumTokens {
            guard maximumTokens > 0 else {
                throw WorkAgentExecutionLimitsError.invalidMaximumTokens
            }
        }
        if let maximumEstimatedCostUSD {
            guard maximumEstimatedCostUSD.isFinite, maximumEstimatedCostUSD > 0 else {
                throw WorkAgentExecutionLimitsError.invalidMaximumEstimatedCostUSD
            }
        }
        self.maximumTokens = maximumTokens
        self.maximumEstimatedCostUSD = maximumEstimatedCostUSD
    }

    /// Decide whether another provider crossing may be admitted.
    ///
    /// The supplied aggregate must belong to this child execution, not the parent-direct Work
    /// total or another child's accounting. When a cost
    /// threshold is finite, the current crossing's pinned admission is required and every
    /// chargeable category must have an explicit finite rate.  In this version a nil cache rate
    /// is unknown rather than "not applicable": the admission does not carry a provider
    /// capability saying that cache reads/writes can never occur, and treating nil as zero would
    /// make a finite threshold unsound.  Callers can configure a zero rate explicitly.
    public func admissionDecision(
        for aggregate: ProviderUsageAggregate,
        providerAdmission: ProviderAdmission? = nil
    ) throws -> WorkAgentExecutionLimitDecision {
        try aggregate.validate()

        if let maximumTokens {
            if aggregate.unresolvedTotal > 0 || aggregate.tokenOverflow {
                return .tokenAccountingUnknown
            }
            if aggregate.knownTokenFloor >= maximumTokens {
                return .tokenThresholdReached
            }
        }

        if let maximumEstimatedCostUSD {
            guard let providerAdmission,
                  Self.hasCompleteCostRates(providerAdmission) else {
                return .costAccountingUnknown
            }
            if aggregate.unresolvedCost > 0 || aggregate.costOverflow {
                return .costAccountingUnknown
            }
            if aggregate.knownCostFloor >= maximumEstimatedCostUSD {
                return .costThresholdReached
            }
        }

        return .allow
    }

    private static func hasCompleteCostRates(_ admission: ProviderAdmission) -> Bool {
        guard (try? admission.validate()) != nil else { return false }
        let rates = admission.rates
        guard rates.invalidRates.isEmpty else { return false }
        // All four categories are potentially chargeable.  The current admission does not
        // declare cache impossibility, so a missing cache rate is an unknown cost, not a zero.
        return rates.inputPerMillion != nil
            && rates.outputPerMillion != nil
            && rates.cacheReadPerMillion != nil
            && rates.cacheWritePerMillion != nil
    }

    /// Strict timeline representation.  Counts are decimal strings because JSONValue numbers
    /// are Doubles; the cost keeps its exact IEEE-754 bit pattern for deterministic replay.
    public var timelineValue: JSONValue {
        var object: [String: JSONValue] = [
            "schema": .number(Double(Self.schemaVersion)),
        ]
        if let maximumTokens {
            object["maximum_tokens"] = .string(String(maximumTokens))
        }
        if let maximumEstimatedCostUSD {
            object["maximum_estimated_cost_usd_bits"] =
                .string(Self.doubleBits(maximumEstimatedCostUSD))
        }
        return .object(object)
    }

    public init(timelineValue: JSONValue) throws {
        guard let object = timelineValue.objectValue else {
            throw WorkAgentExecutionLimitsError.invalidField
        }
        for key in object.keys where key != "schema"
            && key != "maximum_tokens"
            && key != "maximum_estimated_cost_usd_bits" {
            throw WorkAgentExecutionLimitsError.unknownField
        }
        guard let schema = object["schema"], case .number(let schemaNumber) = schema,
              schemaNumber.isFinite, schemaNumber.rounded() == schemaNumber,
              Int(exactly: schemaNumber) == Self.schemaVersion else {
            throw WorkAgentExecutionLimitsError.invalidSchema
        }

        let maximumTokens: Int?
        if let value = object["maximum_tokens"] {
            guard case .string(let encoded) = value else {
                throw WorkAgentExecutionLimitsError.invalidDecimal
            }
            maximumTokens = try Self.decodeDecimal(encoded)
        } else {
            maximumTokens = nil
        }

        let maximumEstimatedCostUSD: Double?
        if let value = object["maximum_estimated_cost_usd_bits"] {
            guard case .string(let encoded) = value else {
                throw WorkAgentExecutionLimitsError.invalidDoubleBits
            }
            maximumEstimatedCostUSD = try Self.decodeDoubleBits(encoded)
        } else {
            maximumEstimatedCostUSD = nil
        }
        try self.init(
            maximumTokens: maximumTokens,
            maximumEstimatedCostUSD: maximumEstimatedCostUSD)
    }

    public init(from decoder: Decoder) throws {
        self = try WorkAgentExecutionLimits(timelineValue: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        try timelineValue.encode(to: encoder)
    }

    public func validate() throws {
        if let maximumTokens, maximumTokens <= 0 {
            throw WorkAgentExecutionLimitsError.invalidMaximumTokens
        }
        if let maximumEstimatedCostUSD,
           !maximumEstimatedCostUSD.isFinite || maximumEstimatedCostUSD <= 0 {
            throw WorkAgentExecutionLimitsError.invalidMaximumEstimatedCostUSD
        }
    }

    private static func decodeDecimal(_ value: String) throws -> Int {
        guard value.utf8.count <= maximumDecimalBytes,
              !value.isEmpty,
              let decoded = Int(value),
              String(decoded) == value else {
            throw WorkAgentExecutionLimitsError.invalidDecimal
        }
        return decoded
    }

    private static func doubleBits(_ value: Double) -> String {
        let digits = String(value.bitPattern, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    private static func decodeDoubleBits(_ value: String) throws -> Double {
        guard value.utf8.count == 16,
              value.unicodeScalars.allSatisfy({
                  (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
              }),
              let bits = UInt64(value, radix: 16) else {
            throw WorkAgentExecutionLimitsError.invalidDoubleBits
        }
        let decoded = Double(bitPattern: bits)
        guard decoded.isFinite, decoded > 0 else {
            throw WorkAgentExecutionLimitsError.invalidDoubleBits
        }
        return decoded
    }
}

public enum WorkAgentExecutionLimitDecision: String, Codable, Hashable, Sendable {
    case allow
    case tokenThresholdReached
    case costThresholdReached
    case tokenAccountingUnknown
    case costAccountingUnknown
}

/// A refused, undispatched crossing. Its pinned admission is needed to verify a cost-policy
/// refusal even when this child has never called a provider. It is not a billed admission.
public struct WorkAgentExecutionLimitRefusal: Codable, Hashable, Sendable, LocalizedError {
    public let decision: WorkAgentExecutionLimitDecision
    public let admission: ProviderAdmission

    public var errorDescription: String? {
        switch decision {
        case .tokenThresholdReached: return "The child reached its token limit; no further model request was sent."
        case .costThresholdReached: return "The child reached its estimated-cost limit; no further model request was sent."
        case .tokenAccountingUnknown: return "The child's token usage is incomplete; its token limit prevented another model request."
        case .costAccountingUnknown: return "The child's usage or pricing is incomplete; its estimated-cost limit prevented another model request."
        case .allow: return "The child execution limit refusal is invalid."
        }
    }

    public init(decision: WorkAgentExecutionLimitDecision, admission: ProviderAdmission) throws {
        guard decision != .allow else { throw WorkAgentExecutionLimitsError.invalidRefusal }
        try admission.validate()
        self.decision = decision
        self.admission = admission
    }

    public func validate(limits: WorkAgentExecutionLimits, usage: ProviderUsageAggregate) throws {
        try admission.validate()
        guard decision != .allow,
              try limits.admissionDecision(for: usage, providerAdmission: admission) == decision else {
            throw WorkAgentExecutionLimitsError.invalidRefusal
        }
    }

    public var timelineValue: JSONValue {
        .object(["decision": .string(decision.rawValue), "admission": admission.timelineValue])
    }

    public init(timelineValue: JSONValue) throws {
        guard let object = timelineValue.objectValue,
              Set(object.keys) == ["decision", "admission"],
              let raw = object["decision"]?.stringValue,
              let decision = WorkAgentExecutionLimitDecision(rawValue: raw),
              let admission = object["admission"] else {
            throw WorkAgentExecutionLimitsError.invalidRefusal
        }
        try self.init(decision: decision, admission: ProviderAdmission(timelineValue: admission))
    }

    public init(from decoder: Decoder) throws {
        try self.init(timelineValue: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        guard decision != .allow else { throw WorkAgentExecutionLimitsError.invalidRefusal }
        try admission.validate()
        try timelineValue.encode(to: encoder)
    }
}

public enum WorkAgentExecutionLimitsError: Error, LocalizedError, Equatable, Sendable {
    case invalidMaximumTokens
    case invalidMaximumEstimatedCostUSD
    case invalidSchema
    case invalidField
    case unknownField
    case invalidDecimal
    case invalidDoubleBits
    case invalidRefusal

    public var errorDescription: String? {
        switch self {
        case .invalidMaximumTokens:
            return "The Work execution token limit must be positive."
        case .invalidMaximumEstimatedCostUSD:
            return "The Work execution USD estimate limit must be finite and positive."
        case .invalidSchema:
            return "The Work execution limits schema is unsupported."
        case .invalidField:
            return "The Work execution limits contain an invalid field."
        case .unknownField:
            return "The Work execution limits contain an unknown field."
        case .invalidDecimal:
            return "The Work execution token limit encoding is invalid."
        case .invalidDoubleBits:
            return "The Work execution USD estimate encoding is invalid."
        case .invalidRefusal:
            return "The Work execution limit refusal does not match its policy and accounting."
        }
    }
}
