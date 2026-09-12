import Foundation
@testable import AviaryCore

private func settlementModel(
    input: Double? = 1.25, output: Double? = 2.5,
    cacheRead: Double? = 0.5, cacheWrite: Double? = 0.75
) -> ModelSpec {
    var model = ModelSpec(rpc: .object([
        "id": .string("settlement-model"),
        "provider": .string("settlement-provider"),
    ]))
    model.costInput = input
    model.costOutput = output
    model.costCacheRead = cacheRead
    model.costCacheWrite = cacheWrite
    return model
}

private func settlementAdmission(
    purpose: ProviderAdmission.Purpose = .normal
) -> ProviderAdmission {
    ProviderAdmission(purpose: purpose, rates: ProviderUsage.RateSnapshot(model: settlementModel()))
}

private func settlementThrows(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        return true
    }
}

let casesProviderSettlement: [Case] = [
    ("provider settlement: timeline codec preserves exact integer boundaries", {
        let admission = settlementAdmission()
        let report = ProviderUsage.RawReport(
            inputTokens: Int.max,
            outputTokens: Int.min,
            cacheReadTokens: 0,
            cacheWriteTokens: 1,
            reasoningTokens: Int.max,
            reportedTotalTokens: Int.min,
            inputAccounting: .cacheExclusive)
        let settlement = ProviderSettlement(
            admission: admission, report: report, finality: .finalReport)
        let value = settlement.timelineValue
        XCTAssertEqual(value["report"]?["input_tokens"], .string(String(Int.max)))
        XCTAssertEqual(value["report"]?["output_tokens"], .string(String(Int.min)))
        XCTAssertEqual(value["report"]?["reasoning_tokens"], .string(String(Int.max)))
        XCTAssertFalse(value["report"]?["input_tokens"]?.isNull ?? true)
        let roundTrip = try ProviderSettlement(timelineValue: value)
        XCTAssertEqual(roundTrip, settlement)
        let encoded = try JSONEncoder().encode(settlement)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(encodedText.contains("\"input_tokens\":\"\(Int.max)\""))
        XCTAssertTrue(encodedText.contains("\"output_tokens\":\"\(Int.min)\""))
        XCTAssertTrue(encodedText.contains("\"input_bits\""))
    }),
    ("provider settlement: strict codec rejects forged fields and numeric counts", {
        let admission = settlementAdmission()
        var admissionObject = admission.timelineValue.objectValue!
        admissionObject["unexpected"] = .string("ignored")
        XCTAssertTrue(settlementThrows {
            _ = try ProviderAdmission(timelineValue: .object(admissionObject))
        })

        var value = ProviderSettlement(
            admission: admission,
            report: ProviderUsage.RawReport(inputTokens: 1, inputAccounting: .cacheExclusive),
            finality: .unconfirmed).timelineValue.objectValue!
        var report = value["report"]!.objectValue!
        report["input_tokens"] = .number(1)
        value["report"] = .object(report)
        XCTAssertTrue(settlementThrows {
            _ = try ProviderSettlement(timelineValue: .object(value))
        })

        let noncanonical = ProviderSettlement(
            admission: admission, report: nil, finality: .finalReport).timelineValue.objectValue!
        var noReport = noncanonical
        noReport["report"] = .object([
            "input_tokens": .string("01"),
            "input_accounting": .string(ProviderUsageAccounting.cacheExclusive.rawValue),
            "malformed_fields": .array([]),
        ])
        XCTAssertTrue(settlementThrows {
            _ = try ProviderSettlement(timelineValue: .object(noReport))
        })

        admissionObject = admission.timelineValue.objectValue!
        XCTAssertFalse(settlementThrows {
            _ = try ProviderAdmission(timelineValue: .object(admissionObject))
        })
        var rates = admissionObject["rates"]!.objectValue!
        rates["input_bits"] = .string("ABCDEF")
        admissionObject["rates"] = .object(rates)
        XCTAssertTrue(settlementThrows {
            _ = try ProviderAdmission(timelineValue: .object(admissionObject))
        })
    }),
    ("provider settlement: purpose and terminal state are validated", {
        let normal = settlementAdmission()
        let compaction = settlementAdmission(purpose: .compaction)
        XCTAssertTrue((try? normal.validate(kind: .provider)) != nil)
        XCTAssertTrue(settlementThrows { try normal.validate(kind: .compactionProvider) })
        XCTAssertTrue((try? compaction.validate(kind: .compactionProvider)) != nil)

        let finalWithoutUsage = ProviderSettlement(
            admission: normal, report: nil, finality: .finalReport)
        XCTAssertTrue((try? finalWithoutUsage.validate(
            admission: normal, kind: .provider, state: .succeeded)) != nil)

        let unconfirmed = ProviderSettlement(
            admission: normal, report: nil, finality: .unconfirmed)
        XCTAssertTrue(settlementThrows {
            try unconfirmed.validate(admission: normal, kind: .provider, state: .succeeded)
        })
        XCTAssertTrue((try? unconfirmed.validate(
            admission: normal, kind: .provider, state: .indeterminateEffect)) != nil)
        XCTAssertTrue(settlementThrows {
            try unconfirmed.validate(admission: normal, kind: .python, state: .failed)
        })
        XCTAssertTrue(settlementThrows {
            try unconfirmed.validate(admission: compaction, kind: .provider, state: .failed)
        })
    }),
    ("provider settlement: aggregate tracks starts, unresolved dimensions, and floors", {
        var aggregate = ProviderUsageAggregate()
        let admission = settlementAdmission()
        let partial = ProviderSettlement(
            admission: admission,
            report: ProviderUsage.RawReport(
                inputTokens: 10, outputTokens: 2, inputAccounting: .cacheExclusive),
            finality: .unconfirmed)
        let complete = ProviderSettlement(
            admission: admission,
            report: ProviderUsage.RawReport(
                inputTokens: 4, outputTokens: 3, cacheReadTokens: 1, cacheWriteTokens: 0,
                reportedTotalTokens: 8, inputAccounting: .cacheExclusive),
            finality: .finalReport)

        XCTAssertTrue(settlementThrows { try aggregate.recordSettlement(partial) })
        try aggregate.recordStarted()
        XCTAssertEqual(aggregate.started, 1)
        XCTAssertEqual(aggregate.settled, 0)
        XCTAssertEqual(aggregate.unresolvedTotal, 1)
        XCTAssertEqual(aggregate.unresolvedBreakdown, 1)
        XCTAssertEqual(aggregate.unresolvedCost, 1)
        try aggregate.recordSettlement(partial)
        XCTAssertEqual(aggregate.settled, 1)
        XCTAssertEqual(aggregate.unresolvedTotal, 1)
        XCTAssertEqual(aggregate.knownTokenFloor, 12)
        XCTAssertTrue(aggregate.knownCostFloor > 0)

        try aggregate.recordStarted()
        XCTAssertEqual(aggregate.unresolvedTotal, 2)
        try aggregate.recordSettlement(complete)
        XCTAssertEqual(aggregate.settled, 2)
        XCTAssertEqual(aggregate.unresolvedTotal, 1)
        XCTAssertEqual(aggregate.unresolvedBreakdown, 1)
        XCTAssertEqual(aggregate.unresolvedCost, 1)
        try aggregate.validate()
        XCTAssertEqual(try ProviderUsageAggregate(timelineValue: aggregate.timelineValue), aggregate)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ProviderUsageAggregate.self,
                from: JSONEncoder().encode(aggregate)),
            aggregate)
    }),
    ("provider settlement: aggregate rejects invalid transitions and preserves overflow truth", {
        var maxed = ProviderUsageAggregate(started: Int.max)
        XCTAssertTrue(settlementThrows { try maxed.recordStarted() })
        XCTAssertTrue(settlementThrows {
            try ProviderUsageAggregate(
                settled: 0,
                knownFloors: .init(totalTokens: 1)).validate()
        })
        XCTAssertTrue(settlementThrows {
            try ProviderUsageAggregate(
                started: 1, settled: 0,
                overflow: .init(tokenCounts: true)).validate()
        })
        XCTAssertTrue(settlementThrows {
            _ = try ProviderUsageAggregate(timelineValue: .object([
                "schema": .number(1),
                "started": .number(1),
            ]))
        })

        let boundary = ProviderUsageAggregate(
            started: 1, settled: 1,
            knownFloors: .init(inputTokens: Int.max, totalTokens: Int.max))
        let decoded = try ProviderUsageAggregate(timelineValue: boundary.timelineValue)
        XCTAssertEqual(decoded.knownTokenFloor, Int.max)

        var saturated = ProviderUsageAggregate()
        let huge = ProviderSettlement(
            admission: settlementAdmission(),
            report: ProviderUsage.RawReport(
                inputTokens: Int.max, outputTokens: 0, cacheReadTokens: 0,
                cacheWriteTokens: 0, reportedTotalTokens: Int.max,
                inputAccounting: .cacheExclusive),
            finality: .finalReport)
        try saturated.recordStarted()
        try saturated.recordSettlement(huge)
        try saturated.recordStarted()
        try saturated.recordSettlement(huge)
        XCTAssertTrue(saturated.tokenOverflow)
        XCTAssertEqual(saturated.knownTokenFloor, Int.max)
        XCTAssertEqual(saturated.unresolvedTotal, 1)
        XCTAssertEqual(saturated.unresolvedBreakdown, 1)
        try saturated.validate()

        var componentOverflow = ProviderUsageAggregate()
        try componentOverflow.recordStarted()
        try componentOverflow.recordSettlement(ProviderSettlement(
            admission: settlementAdmission(),
            report: .init(inputTokens: Int.max, outputTokens: 1,
                          cacheReadTokens: 0, cacheWriteTokens: 0,
                          inputAccounting: .cacheExclusive),
            finality: .finalReport))
        XCTAssertEqual(componentOverflow.settled, 1)
        XCTAssertTrue(componentOverflow.tokenOverflow)
        XCTAssertEqual(componentOverflow.unresolvedTotal, 1)
        XCTAssertEqual(componentOverflow.unresolvedBreakdown, 1)
        XCTAssertEqual(try ProviderUsageAggregate(timelineValue: componentOverflow.timelineValue),
                       componentOverflow)

        let exact = ProviderUsageAggregate(started: 1, settled: 1,
            knownFloors: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2))
        try exact.validate()
        let falseZero = ProviderUsageAggregate(started: 1, settled: 1,
            knownFloors: .init(inputTokens: 1, outputTokens: 1, totalTokens: 0))
        XCTAssertTrue(settlementThrows {
            _ = try ProviderUsageAggregate(timelineValue: falseZero.timelineValue)
        })
    }),
]
