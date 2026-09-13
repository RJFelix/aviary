import Foundation
@testable import AviaryCore

private func workAgentExecutionLimitsThrows(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        return true
    }
}

private func workAgentExecutionLimitsAdmission(
    provider: String = "limits-provider",
    modelID: String = "limits-model",
    input: Double? = 1,
    output: Double? = 1,
    cacheRead: Double? = 1,
    cacheWrite: Double? = 1
) -> ProviderAdmission {
    var model = ModelSpec(rpc: .object([
        "id": .string(modelID),
        "provider": .string(provider),
    ]))
    model.costInput = input
    model.costOutput = output
    model.costCacheRead = cacheRead
    model.costCacheWrite = cacheWrite
    return ProviderAdmission(
        purpose: .normal,
        rates: ProviderUsage.RateSnapshot(model: model))
}

private func workAgentExecutionLimitsCostAggregate(_ cost: Double) -> ProviderUsageAggregate {
    ProviderUsageAggregate(
        started: 1,
        settled: 1,
        knownFloors: .init(cost: cost))
}

let casesWorkAgentExecutionLimits: [Case] = [
    ("Work execution limits: strict timeline and constructor bounds", {
        let limits = try WorkAgentExecutionLimits(
            maximumTokens: Int.max,
            maximumEstimatedCostUSD: 1.5)
        let value = limits.timelineValue
        XCTAssertEqual(value["schema"], .number(1))
        XCTAssertEqual(value["maximum_tokens"], .string(String(Int.max)))
        XCTAssertEqual(
            value["maximum_estimated_cost_usd_bits"],
            .string("3ff8000000000000"))
        XCTAssertEqual(try WorkAgentExecutionLimits(timelineValue: value), limits)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkAgentExecutionLimits.self,
                from: JSONEncoder().encode(limits)),
            limits)

        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(maximumTokens: 0)
        })
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(maximumTokens: -1)
        })
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(maximumEstimatedCostUSD: 0)
        })
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(maximumEstimatedCostUSD: -.infinity)
        })
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(maximumEstimatedCostUSD: .nan)
        })
    }),
    ("Work execution limits: codec rejects forged fields and noncanonical values", {
        var unknown = try WorkAgentExecutionLimits(maximumTokens: 1).timelineValue.objectValue!
        unknown["extra"] = .string("not accepted")
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(timelineValue: .object(unknown))
        })

        var numeric = try WorkAgentExecutionLimits(maximumTokens: 1).timelineValue.objectValue!
        numeric["maximum_tokens"] = .number(1)
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(timelineValue: .object(numeric))
        })

        var noncanonical = try WorkAgentExecutionLimits(maximumTokens: 1).timelineValue.objectValue!
        noncanonical["maximum_tokens"] = .string("01")
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(timelineValue: .object(noncanonical))
        })

        var uppercaseBits = try WorkAgentExecutionLimits(maximumEstimatedCostUSD: 1).timelineValue.objectValue!
        uppercaseBits["maximum_estimated_cost_usd_bits"] = .string("3FF0000000000000")
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(timelineValue: .object(uppercaseBits))
        })

        var missingSchema = try WorkAgentExecutionLimits(maximumTokens: 1).timelineValue.objectValue!
        missingSchema.removeValue(forKey: "schema")
        XCTAssertTrue(workAgentExecutionLimitsThrows {
            _ = try WorkAgentExecutionLimits(timelineValue: .object(missingSchema))
        })
    }),
    ("Work execution limits: unlimited and token boundaries", {
        let empty = ProviderUsageAggregate()
        let unlimited = try WorkAgentExecutionLimits()
        XCTAssertEqual(
            try unlimited.admissionDecision(for: empty),
            .allow)

        let tokenLimit = try WorkAgentExecutionLimits(maximumTokens: 1)
        XCTAssertEqual(
            try tokenLimit.admissionDecision(for: empty),
            .allow)
        let atLimit = ProviderUsageAggregate(
            started: 1,
            settled: 1,
            knownFloors: .init(inputTokens: 1, totalTokens: 1))
        XCTAssertEqual(
            try tokenLimit.admissionDecision(for: atLimit),
            .tokenThresholdReached)
        let belowLimit = ProviderUsageAggregate(
            started: 1,
            settled: 1,
            knownFloors: .init(totalTokens: 0))
        XCTAssertEqual(
            try tokenLimit.admissionDecision(for: belowLimit),
            .allow)
    }),
    ("Work execution limits: token uncertainty is dimension-specific", {
        let tokenLimit = try WorkAgentExecutionLimits(maximumTokens: 10)
        let costUnknown = ProviderUsageAggregate(
            started: 1,
            settled: 1,
            unresolved: .init(cost: 1))
        XCTAssertEqual(
            try tokenLimit.admissionDecision(for: costUnknown),
            .allow)

        let tokenUnknown = ProviderUsageAggregate(
            started: 1,
            settled: 1,
            unresolved: .init(total: 1))
        XCTAssertEqual(
            try tokenLimit.admissionDecision(for: tokenUnknown),
            .tokenAccountingUnknown)

        let overflow = ProviderUsageAggregate(
            started: 1,
            settled: 1,
            unresolved: .init(total: 1, breakdown: 1),
            knownFloors: .init(totalTokens: Int.max),
            overflow: .init(tokenCounts: true))
        XCTAssertEqual(
            try tokenLimit.admissionDecision(for: overflow),
            .tokenAccountingUnknown)
    }),
    ("Work execution limits: finite cost needs pinned complete rates", {
        let costLimit = try WorkAgentExecutionLimits(maximumEstimatedCostUSD: 1)
        let empty = ProviderUsageAggregate()
        XCTAssertEqual(
            try costLimit.admissionDecision(for: empty),
            .costAccountingUnknown)
        XCTAssertEqual(
            try costLimit.admissionDecision(
                for: empty,
                providerAdmission: workAgentExecutionLimitsAdmission(cacheRead: nil)),
            .costAccountingUnknown)
        XCTAssertEqual(
            try costLimit.admissionDecision(
                for: empty,
                providerAdmission: workAgentExecutionLimitsAdmission(input: -1)),
            .costAccountingUnknown)
        XCTAssertEqual(
            try costLimit.admissionDecision(
                for: empty,
                providerAdmission: workAgentExecutionLimitsAdmission()),
            .allow)
    }),
    ("Work execution limits: cost threshold and uncertainty", {
        let admission = workAgentExecutionLimitsAdmission()
        let knownCost = 0.25
        let below = try WorkAgentExecutionLimits(maximumEstimatedCostUSD: 0.5)
        XCTAssertEqual(
            try below.admissionDecision(
                for: workAgentExecutionLimitsCostAggregate(knownCost),
                providerAdmission: admission),
            .allow)

        let at = try WorkAgentExecutionLimits(maximumEstimatedCostUSD: knownCost)
        XCTAssertEqual(
            try at.admissionDecision(
                for: workAgentExecutionLimitsCostAggregate(knownCost),
                providerAdmission: admission),
            .costThresholdReached)

        let unresolved = ProviderUsageAggregate(
            started: 1,
            settled: 1,
            unresolved: .init(cost: 1),
            knownFloors: .init(cost: knownCost))
        XCTAssertEqual(
            try below.admissionDecision(for: unresolved, providerAdmission: admission),
            .costAccountingUnknown)

        let overflow = ProviderUsageAggregate(
            started: 1,
            settled: 1,
            unresolved: .init(cost: 1),
            knownFloors: .init(cost: Double.greatestFiniteMagnitude),
            overflow: .init(cost: true))
        XCTAssertEqual(
            try below.admissionDecision(for: overflow, providerAdmission: admission),
            .costAccountingUnknown)
    }),
    ("Work execution limits: mixed-provider usage remains aggregate-scoped", {
        let firstAdmission = workAgentExecutionLimitsAdmission(
            provider: "provider-a", modelID: "model-a", input: 1, output: 2)
        let secondAdmission = workAgentExecutionLimitsAdmission(
            provider: "provider-b", modelID: "model-b", input: 100, output: 200)
        var aggregate = ProviderUsageAggregate()
        try aggregate.recordStarted()
        try aggregate.recordSettlement(ProviderSettlement(
            admission: firstAdmission,
            report: .init(
                inputTokens: 1, outputTokens: 1,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                inputAccounting: .cacheExclusive),
            finality: .finalReport))
        try aggregate.recordStarted()
        try aggregate.recordSettlement(ProviderSettlement(
            admission: secondAdmission,
            report: .init(
                inputTokens: 1, outputTokens: 1,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                inputAccounting: .cacheExclusive),
            finality: .finalReport))
        XCTAssertTrue(aggregate.knownCostFloor > 0)

        let exact = try WorkAgentExecutionLimits(
            maximumEstimatedCostUSD: aggregate.knownCostFloor)
        XCTAssertEqual(
            try exact.admissionDecision(
                for: aggregate,
                providerAdmission: secondAdmission),
            .costThresholdReached)
        let above = try WorkAgentExecutionLimits(
            maximumEstimatedCostUSD: aggregate.knownCostFloor + 1)
        XCTAssertEqual(
            try above.admissionDecision(
                for: aggregate,
                providerAdmission: secondAdmission),
            .allow)
    }),
]
