import Foundation
@testable import AviaryCore

private func providerUsageModel(
    input: Double? = 2, output: Double? = 4,
    cacheRead: Double? = 0.5, cacheWrite: Double? = 1
) -> ModelSpec {
    var model = ModelSpec(rpc: .object([
        "id": .string("usage-model"), "provider": .string("usage-provider")
    ]))
    model.costInput = input
    model.costOutput = output
    model.costCacheRead = cacheRead
    model.costCacheWrite = cacheWrite
    return model
}

let casesProviderUsage: [Case] = [
    ("usage accounting: inclusive separates ordinary cache input", {
        let report = ProviderUsage.RawReport(
            inputTokens: 100, outputTokens: 20, cacheReadTokens: 30, cacheWriteTokens: 10,
            reportedTotalTokens: 120, inputAccounting: .cacheInclusive)
        let result = ProviderUsage.account(report: report, model: providerUsageModel())
        XCTAssertEqual(result.inputAccounting, .cacheInclusive)
        XCTAssertEqual(result.ordinaryInputTokens, 60)
        XCTAssertEqual(result.contextTokens, 100)
        XCTAssertEqual(result.totalTokens, 120)
        XCTAssertEqual(result.price.input.count, 60)
        XCTAssertEqual(result.price.cacheRead.count, 30)
        XCTAssertEqual(result.price.cacheWrite.count, 10)
        XCTAssertEqual(result.price.completeness, .complete)
        XCTAssertTrue(abs((result.price.total ?? -1) - 0.000225) < 0.000000001)
    }),
    ("usage accounting: exclusive cache fields form context", {
        let report = ProviderUsage.RawReport(
            inputTokens: 0, outputTokens: 5, cacheReadTokens: 40, cacheWriteTokens: 10,
            reportedTotalTokens: 55, inputAccounting: .cacheExclusive)
        let result = ProviderUsage.account(report: report, model: providerUsageModel())
        XCTAssertEqual(result.ordinaryInputTokens, 0)
        XCTAssertEqual(result.contextTokens, 50)
        XCTAssertEqual(result.totalTokens, 55)
        XCTAssertEqual(result.price.input.amount, 0)
        XCTAssertEqual(result.price.completeness, .complete)
    }),
    ("usage accounting: absent and explicit zero remain distinct", {
        let absent = ProviderUsage.account(
            report: ProviderUsage.RawReport(inputTokens: 4, outputTokens: 0,
                inputAccounting: .cacheExclusive), model: providerUsageModel())
        XCTAssertEqual(absent.observations.cacheReadTokens.state, .missing)
        XCTAssertEqual(absent.observations.cacheReadTokens.reason, .notReported)
        XCTAssertNil(absent.contextTokens)
        XCTAssertEqual(absent.price.completeness, .partial)

        let zero = ProviderUsage.account(
            report: ProviderUsage.RawReport(inputTokens: 4, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, inputAccounting: .cacheExclusive),
            model: providerUsageModel())
        XCTAssertEqual(zero.observations.cacheReadTokens.state, .known)
        XCTAssertEqual(zero.observations.cacheReadTokens.value, 0)
        XCTAssertEqual(zero.contextTokens, 4)
        XCTAssertEqual(zero.price.cacheRead.amount, 0)
        XCTAssertEqual(zero.price.completeness, .complete)

        let missingCountZeroRate = ProviderUsage.account(
            report: ProviderUsage.RawReport(
                outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 0,
                inputAccounting: .cacheExclusive),
            model: providerUsageModel(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)).price
        XCTAssertNil(missingCountZeroRate.input.amount)
        XCTAssertTrue(missingCountZeroRate.issues.contains(.missingCount))
        XCTAssertEqual(missingCountZeroRate.completeness, .unavailable)

        let noReport = ProviderUsage.account(report: nil, model: providerUsageModel())
        XCTAssertEqual(noReport.observations.inputTokens.reason, .noReport)
        XCTAssertEqual(noReport.price.completeness, .unavailable)
        XCTAssertNil(noReport.price.total)
        XCTAssertEqual(
            ProviderUsage.account(report: nil,
                model: providerUsageModel(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
                .price.completeness,
            .unavailable)
    }),
    ("usage accounting: malformed negative and integer overflow never become zero", {
        let malformed = ProviderUsage.account(
            report: ProviderUsage.RawReport(inputTokens: 10, outputTokens: -1,
                cacheReadTokens: 2, cacheWriteTokens: 1,
                inputAccounting: .cacheExclusive, malformedFields: [.cacheReadTokens]),
            model: providerUsageModel())
        XCTAssertEqual(malformed.observations.outputTokens.state, .invalid)
        XCTAssertEqual(malformed.observations.outputTokens.reason, .negative)
        XCTAssertEqual(malformed.observations.cacheReadTokens.reason, .malformed)
        XCTAssertNil(malformed.totalTokens)
        XCTAssertEqual(malformed.price.output.amount, nil)

        let overflow = ProviderUsage.account(
            report: ProviderUsage.RawReport(inputTokens: Int.max, outputTokens: 1,
                cacheReadTokens: 0, cacheWriteTokens: 0, inputAccounting: .cacheExclusive),
            model: providerUsageModel())
        XCTAssertEqual(overflow.contextTokens, Int.max, "only the total overflows, not the context count")
        XCTAssertNil(overflow.totalTokens)
        XCTAssertTrue(overflow.issues.contains(.arithmeticOverflow))

        let inconsistent = ProviderUsage.account(
            report: ProviderUsage.RawReport(inputTokens: 10, outputTokens: 2,
                cacheReadTokens: 8, cacheWriteTokens: 5, inputAccounting: .cacheInclusive),
            model: providerUsageModel())
        XCTAssertEqual(inconsistent.contextTokens, 10)
        XCTAssertEqual(inconsistent.totalTokens, 12)
        XCTAssertNil(inconsistent.ordinaryInputTokens)
        XCTAssertTrue(inconsistent.issues.contains(.inconsistentCachePartition))
        XCTAssertFalse(inconsistent.issues.contains(.arithmeticOverflow))
    }),
    ("usage accounting: reasoning is a subset and supplied total is an audit", {
        let result = ProviderUsage.account(
            report: ProviderUsage.RawReport(inputTokens: 10, outputTokens: 20,
                cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 25,
                reportedTotalTokens: 999, inputAccounting: .cacheExclusive),
            model: providerUsageModel())
        XCTAssertEqual(result.reasoningTokens, nil)
        XCTAssertEqual(result.observations.reasoningTokens.reason, .reasoningExceedsOutput)
        XCTAssertEqual(result.totalTokens, 30)
        XCTAssertTrue(result.issues.contains(.reasoningExceedsOutput))
        XCTAssertTrue(result.issues.contains(.reportedTotalMismatch))
    }),
    ("usage accounting: rates require finite explicit nonnegative values", {
        let report = ProviderUsage.RawReport(
            inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 0,
            inputAccounting: .cacheExclusive)
        var invalid = providerUsageModel(input: .nan, output: -.infinity, cacheRead: -1, cacheWrite: 0)
        let invalidPrice = ProviderUsage.account(report: report, model: invalid).price
        XCTAssertEqual(invalidPrice.input.amount, nil)
        XCTAssertEqual(invalidPrice.output.amount, nil)
        XCTAssertEqual(invalidPrice.cacheRead.amount, nil)
        XCTAssertTrue(invalidPrice.issues.contains(.invalidRate))
        XCTAssertEqual(invalidPrice.completeness, .unavailable)

        invalid.costInput = 0
        invalid.costOutput = 0
        invalid.costCacheRead = 0
        let zeroRate = ProviderUsage.account(report: report, model: invalid).price
        XCTAssertEqual(zeroRate.input.amount, 0)
        XCTAssertEqual(zeroRate.output.amount, 0)
        XCTAssertEqual(zeroRate.cacheRead.amount, 0)
        XCTAssertEqual(zeroRate.total, 0)
        XCTAssertEqual(zeroRate.completeness, .complete)

        let invalidZero = ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 0, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 0,
                inputAccounting: .cacheExclusive),
            model: providerUsageModel(input: -.infinity, output: 4,
                cacheRead: 0.5, cacheWrite: 1)).price
        XCTAssertEqual(invalidZero.input.amount, nil)
        XCTAssertTrue(invalidZero.issues.contains(.invalidRate))

        let missingRate = ProviderUsage.account(
            report: report, model: providerUsageModel(input: nil, output: 4, cacheRead: 0.5, cacheWrite: 1))
            .price
        XCTAssertEqual(missingRate.input.amount, nil)
        XCTAssertTrue(missingRate.issues.contains(.missingRate))
        XCTAssertNil(missingRate.total)

        let entirelyUnpriced = ProviderUsage.account(
            report: report, model: providerUsageModel(input: nil, output: nil,
                cacheRead: nil, cacheWrite: nil)).price
        XCTAssertEqual(entirelyUnpriced.completeness, .unavailable)
        XCTAssertEqual(entirelyUnpriced.knownTotal, 0)

        let costOverflow = ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 1_000_000, outputTokens: 1_000_000,
                cacheReadTokens: 0, cacheWriteTokens: 0, inputAccounting: .cacheExclusive),
            model: providerUsageModel(input: 1e308, output: 1e308, cacheRead: 0, cacheWrite: 0)).price
        XCTAssertTrue(costOverflow.issues.contains(.arithmeticOverflow))
        XCTAssertTrue(costOverflow.knownTotalIsLowerBound)
        XCTAssertNil(costOverflow.total)

        let underflow = ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 1, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                inputAccounting: .cacheExclusive),
            model: providerUsageModel(input: Double.leastNonzeroMagnitude, output: 0,
                cacheRead: 0, cacheWrite: 0)).price
        XCTAssertNil(underflow.input.amount)
        XCTAssertTrue(underflow.issues.contains(.arithmeticUnderflow))
        XCTAssertEqual(underflow.completeness, .unavailable)
    }),
    ("usage accounting: bounded Codable metadata excludes non-finite rates", {
        let report = ProviderUsage.RawReport(
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0,
            inputAccounting: .cacheExclusive)
        let result = ProviderUsage.account(report: report, model: providerUsageModel(input: .nan))
        do {
            let data = try JSONEncoder().encode(result)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("NaN"))
            let decoded = try JSONDecoder().decode(ProviderUsage.AccountedCrossing.self, from: data)
            XCTAssertEqual(decoded.rateSnapshot.providerID, "usage-provider")
            XCTAssertTrue(decoded.rateSnapshot.invalidRates.contains(.input))
            XCTAssertEqual(decoded.rawReport?.inputAccounting, .cacheExclusive)
        } catch {
            XCTFail("bounded provider usage should round-trip: \(error)")
        }
        var unversioned = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        unversioned.removeValue(forKey: "schema")
        do {
            _ = try JSONDecoder().decode(ProviderUsage.AccountedCrossing.self,
                from: JSONSerialization.data(withJSONObject: unversioned))
            XCTFail("an owned accounting envelope requires its schema")
        } catch { XCTAssertTrue(true) }

        let longIdentity = String(repeating: "x", count: 300)
        var longModel = ModelSpec(rpc: .object([
            "id": .string(longIdentity), "provider": .string(longIdentity)
        ]))
        longModel.costInput = 0; longModel.costOutput = 0
        longModel.costCacheRead = 0; longModel.costCacheWrite = 0
        let bounded = ProviderUsage.account(report: report, model: longModel).rateSnapshot
        XCTAssertTrue(bounded.modelID.utf8.count <= 256)
        XCTAssertTrue(bounded.providerID.utf8.count <= 256)
        XCTAssertNotEqual(bounded.modelID, longIdentity)
        XCTAssertNotEqual(bounded.providerID, longIdentity)

        let oversizedJSON = Data("{\"schema\":1,\"rateSnapshot\":{\"providerID\":\"\(longIdentity)\",\"modelID\":\"m\"}}".utf8)
        do {
            _ = try JSONDecoder().decode(ProviderUsage.AccountedCrossing.self, from: oversizedJSON)
            XCTFail("oversized persisted rate identity must be rejected")
        } catch {
            XCTAssertTrue(true)
        }
    }),
]
