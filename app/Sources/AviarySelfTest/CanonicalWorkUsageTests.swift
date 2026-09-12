import Foundation
@testable import AviaryCore

private func canonicalWorkUsageAdmission(
    purpose: ProviderAdmission.Purpose = .normal
) -> ProviderAdmission {
    var model = ModelSpec(rpc: .object([
        "id": .string("canonical-work-usage-model"),
        "provider": .string("canonical-work-usage-provider"),
    ]))
    model.costInput = 1
    model.costOutput = 2
    model.costCacheRead = 0.5
    model.costCacheWrite = 0.75
    return ProviderAdmission(
        purpose: purpose, rates: ProviderUsage.RateSnapshot(model: model))
}

private func canonicalWorkUsageSettlement(
    purpose: ProviderAdmission.Purpose = .normal,
    report: ProviderUsage.RawReport?,
    finality: ProviderUsage.ReportFinality
) -> ProviderSettlement {
    ProviderSettlement(
        admission: canonicalWorkUsageAdmission(purpose: purpose),
        report: report, finality: finality)
}

private func canonicalWorkUsageThrows(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        return true
    }
}

let casesCanonicalWorkUsage: [Case] = [
    ("canonical Work usage preserves failed and compaction crossings", {
        var aggregate = ProviderUsageAggregate()
        try aggregate.recordStarted()
        try aggregate.recordSettlement(canonicalWorkUsageSettlement(
            report: ProviderUsage.RawReport(
                inputTokens: 10, outputTokens: 4, cacheReadTokens: 0, cacheWriteTokens: 0, reportedTotalTokens: 14,
                inputAccounting: .cacheExclusive),
            finality: .unconfirmed))

        try aggregate.recordStarted()
        try aggregate.recordSettlement(canonicalWorkUsageSettlement(
            purpose: .compaction,
            report: ProviderUsage.RawReport(
                inputTokens: 2, outputTokens: 3, cacheReadTokens: 0, cacheWriteTokens: 0, reportedTotalTokens: 5,
                inputAccounting: .cacheExclusive),
            finality: .finalReport))

        let usage = CanonicalWorkUsage(aggregate: aggregate)
        XCTAssertEqual(usage.startedCrossings, 2)
        XCTAssertEqual(usage.settledCrossings, 2)
        XCTAssertEqual(usage.outstandingCrossings, 0)
        XCTAssertEqual(usage.unresolvedTotal, 1)
        XCTAssertEqual(usage.unresolvedBreakdown, 1)
        XCTAssertEqual(usage.unresolvedCost, 1)
        XCTAssertTrue(usage.knownTokenFloor > 0)
        XCTAssertEqual(usage.totalTokenCertainty, .lowerBound)
        XCTAssertEqual(usage.breakdownCertainty, .lowerBound)
        XCTAssertEqual(usage.costCertainty, .lowerBound)
        XCTAssertTrue(usage.hasCrossingEvidence)
        XCTAssertTrue(usage.hasUnresolvedAccounting)
    }),
    ("canonical Work usage keeps unknown and overflow truth", {
        let unknownAggregate = ProviderUsageAggregate(
            started: 1, settled: 1,
            unresolved: .init(total: 1, breakdown: 1, cost: 1))
        XCTAssertFalse(canonicalWorkUsageThrows { try unknownAggregate.validate() })
        let unknown = CanonicalWorkUsage(aggregate: unknownAggregate)
        XCTAssertEqual(unknown.knownTokenFloor, 0)
        XCTAssertEqual(unknown.totalTokenCertainty, .unknown)
        XCTAssertEqual(unknown.breakdownCertainty, .unknown)
        XCTAssertEqual(unknown.costCertainty, .unknown)
        XCTAssertTrue(unknown.hasUnresolvedAccounting)

        var overflowAggregate = ProviderUsageAggregate()
        try overflowAggregate.recordStarted()
        try overflowAggregate.recordSettlement(canonicalWorkUsageSettlement(
            report: ProviderUsage.RawReport(
                inputTokens: Int.max, outputTokens: 1,
                inputAccounting: .cacheExclusive),
            finality: .finalReport))
        let overflow = CanonicalWorkUsage(aggregate: overflowAggregate)
        XCTAssertTrue(overflow.tokenOverflow)
        XCTAssertEqual(overflow.totalTokenCertainty, .unknown)
        XCTAssertEqual(overflow.breakdownCertainty, .unknown)
        XCTAssertTrue(overflow.hasUnresolvedAccounting)
    }),
    ("canonical Work usage is stable across two Session attachments", {
        var aggregate = ProviderUsageAggregate()
        try aggregate.recordStarted()
        try aggregate.recordSettlement(canonicalWorkUsageSettlement(
            report: ProviderUsage.RawReport(
                inputTokens: 11, outputTokens: 7, cacheReadTokens: 0, cacheWriteTokens: 0, reportedTotalTokens: 18,
                inputAccounting: .cacheExclusive),
            finality: .finalReport))
        try aggregate.validate()

        // Two GUI attachments to the same Work receive the same Work-lifetime value.  The
        // DTO has no Session field by design, so a caller cannot accidentally sum it once per
        // attachment while constructing a Session-level report.
        let firstAttachment = CanonicalWorkUsage(aggregate: aggregate)
        let secondAttachment = CanonicalWorkUsage(aggregate: aggregate)
        XCTAssertEqual(firstAttachment, secondAttachment)
        XCTAssertEqual(firstAttachment.startedCrossings, 1)
        XCTAssertEqual(firstAttachment.settledCrossings, 1)
        XCTAssertEqual(firstAttachment.unresolvedTotal, 0)
        XCTAssertEqual(firstAttachment.totalTokenCertainty, .exact)
        XCTAssertEqual(firstAttachment.breakdownCertainty, .exact)
        XCTAssertEqual(firstAttachment.costCertainty, .exact)
    }),
]
