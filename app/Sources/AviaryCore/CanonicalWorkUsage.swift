import Foundation

/// The display projection of provider accounting for one canonical Work.
///
/// This is deliberately a Work-lifetime value, not a Session or Run total.  A Work may have
/// several attached Sessions and GUIs, so callers must render one value for the Work rather
/// than adding it to each attached conversation.  The projection keeps the aggregate's
/// unresolved dimensions and overflow flags instead of turning an unknown value into zero.
public struct CanonicalWorkUsage: Hashable, Sendable {
    public enum Certainty: String, Codable, Hashable, Sendable {
        case exact
        /// A positive value is a known lower bound, but one or more observations remain
        /// unresolved.
        case lowerBound = "lower_bound"
        /// No positive lower bound is available, or arithmetic overflow prevents a finite
        /// quantitative claim.
        case unknown
    }

    public let startedCrossings: Int
    public let settledCrossings: Int
    public let outstandingCrossings: Int

    /// These are aggregate lower-bound fields.  They are kept separate from the legacy
    /// ``Usage`` shape because ``Usage`` cannot represent Work-wide unresolved dimensions.
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let knownTokenFloor: Int
    public let knownCostFloor: Double

    public let unresolvedTotal: Int
    public let unresolvedBreakdown: Int
    public let unresolvedCost: Int
    public let tokenOverflow: Bool
    public let costOverflow: Bool

    public init(aggregate: ProviderUsageAggregate) {
        startedCrossings = aggregate.started
        settledCrossings = aggregate.settled
        outstandingCrossings = max(0, aggregate.started - aggregate.settled)
        inputTokens = aggregate.knownFloors.inputTokens
        outputTokens = aggregate.knownFloors.outputTokens
        cacheReadTokens = aggregate.knownFloors.cacheReadTokens
        cacheWriteTokens = aggregate.knownFloors.cacheWriteTokens
        knownTokenFloor = aggregate.knownTokenFloor
        knownCostFloor = aggregate.knownCostFloor
        unresolvedTotal = aggregate.unresolvedTotal
        unresolvedBreakdown = aggregate.unresolvedBreakdown
        unresolvedCost = aggregate.unresolvedCost
        tokenOverflow = aggregate.tokenOverflow
        costOverflow = aggregate.costOverflow
    }

    /// Whether the Work has any provider crossing evidence at all.  A canonical idle Work can
    /// validly return false and should be shown as having no crossings, not as unavailable.
    public var hasCrossingEvidence: Bool {
        startedCrossings > 0 || settledCrossings > 0
    }

    public var hasUnresolvedAccounting: Bool {
        unresolvedTotal > 0 || unresolvedBreakdown > 0 || unresolvedCost > 0
            || tokenOverflow || costOverflow
    }

    /// Certainty of the aggregate reported total, independent of whether component breakdown
    /// fields are still unresolved.
    public var totalTokenCertainty: Certainty {
        if tokenOverflow { return .unknown }
        if unresolvedTotal == 0 { return .exact }
        return knownTokenFloor > 0 ? .lowerBound : .unknown
    }

    /// Certainty of the input/output/cache component fields taken together.
    public var breakdownCertainty: Certainty {
        if tokenOverflow { return .unknown }
        if unresolvedBreakdown == 0 { return .exact }
        return knownTokenFloor > 0 ? .lowerBound : .unknown
    }

    public var costCertainty: Certainty {
        if costOverflow { return .unknown }
        if unresolvedCost == 0 { return .exact }
        return knownCostFloor > 0 ? .lowerBound : .unknown
    }
}
