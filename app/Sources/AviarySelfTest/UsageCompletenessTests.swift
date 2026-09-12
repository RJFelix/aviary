import Foundation
@testable import AviaryCore

let casesUsageCompleteness: [Case] = [
    ("usage DTO requires final report evidence for exact crossing totals", {
        let model = usageCompletenessModel()
        let crossing = ProviderUsage.account(report: .init(
            inputTokens: 10, outputTokens: 2, cacheReadTokens: 0, cacheWriteTokens: 0,
            inputAccounting: .cacheExclusive), model: model)
        let provisional = Usage(finality: .unconfirmed, accounted: crossing)
        let final = Usage(finality: .finalReport, accounted: crossing)
        XCTAssertEqual(provisional.totalTokens, final.totalTokens)
        XCTAssertEqual(provisional.cost, final.cost)
        XCTAssertEqual(provisional.completeness.tokenTotal, .lowerBound)
        XCTAssertEqual(provisional.completeness.breakdown, .lowerBound)
        XCTAssertEqual(provisional.completeness.cost, .lowerBound)
        XCTAssertTrue(final.isTokenTotalComplete)
        XCTAssertTrue(final.isCostComplete)
        XCTAssertEqual(try JSONDecoder().decode(Usage.self,
            from: JSONEncoder().encode(provisional)), provisional)
        let missing = Usage(finality: .unconfirmed,
            accounted: ProviderUsage.account(report: nil, model: model))
        XCTAssertEqual(missing.completeness.tokenTotal, .unavailable)
        XCTAssertEqual(missing.completeness.cost, .unavailable)
    }),
    ("usage DTO normalizes inclusive and exclusive crossings before aggregation", {
        let model = usageCompletenessModel()
        let inclusive = Usage(finality: .finalReport, accounted: ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 100, outputTokens: 20, cacheReadTokens: 30,
                cacheWriteTokens: 10, reportedTotalTokens: 120,
                inputAccounting: .cacheInclusive),
            model: model))
        let exclusive = Usage(finality: .finalReport, accounted: ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 10, outputTokens: 5, cacheReadTokens: 5,
                cacheWriteTokens: 0, reportedTotalTokens: 20,
                inputAccounting: .cacheExclusive),
            model: model))

        XCTAssertEqual(inclusive.input, 60)
        XCTAssertEqual(inclusive.totalTokens, 120)
        XCTAssertTrue(inclusive.isTokenTotalComplete)
        XCTAssertTrue(inclusive.isCostComplete)
        let total = inclusive + exclusive
        XCTAssertEqual(total.input, 70)
        XCTAssertEqual(total.cacheRead, 35)
        XCTAssertEqual(total.cacheWrite, 10)
        XCTAssertEqual(total.output, 25)
        XCTAssertEqual(total.totalTokens, 140)
        XCTAssertEqual(total.completeness.inputAccounting, .mixed)
        XCTAssertTrue(total.isTokenTotalComplete)
        XCTAssertTrue(total.isCostComplete)
    }),
    ("usage DTO keeps exact inclusive total when cache partition is invalid", {
        let usage = Usage(finality: .finalReport, accounted: ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 1, outputTokens: 2, cacheReadTokens: 100,
                cacheWriteTokens: 1, reportedTotalTokens: 3,
                inputAccounting: .cacheInclusive),
            model: usageCompletenessModel()))
        XCTAssertEqual(usage.totalTokens, 3)
        XCTAssertTrue(usage.isTokenTotalComplete)
        XCTAssertFalse(usage.isBreakdownComplete)
        XCTAssertFalse(usage.isCostComplete)
        XCTAssertEqual(usage.cost.input, 0)
        XCTAssertEqual(usage.cost.cacheRead, 0)
        XCTAssertTrue(usage.cost.output > 0)
        XCTAssertEqual(usage.cacheRead, 0)
        XCTAssertEqual(usage.cacheWrite, 0)
        let roundTrip = try JSONDecoder().decode(
            Usage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(roundTrip.totalTokens, 3)
        XCTAssertEqual(roundTrip.completeness.breakdown, .lowerBound)
        for (read, write) in [(Optional(100), Optional<Int>.none), (nil, Optional(100))] {
            let crossing = ProviderUsage.account(report: .init(
                inputTokens: 1, outputTokens: 2, cacheReadTokens: read,
                cacheWriteTokens: write, inputAccounting: .cacheInclusive),
                model: usageCompletenessModel())
            XCTAssertTrue(crossing.issues.contains(.inconsistentCachePartition))
            XCTAssertNil(crossing.price.cacheRead.amount)
            XCTAssertNil(crossing.price.cacheWrite.amount)
            XCTAssertEqual(crossing.price.knownTotal, crossing.price.output.amount ?? 0)
            let projected = Usage(finality: .finalReport, accounted: crossing)
            XCTAssertEqual(projected.totalTokens, 3)
            XCTAssertEqual(projected.cacheRead, 0)
            XCTAssertEqual(projected.cacheWrite, 0)
            XCTAssertEqual(try JSONDecoder().decode(Usage.self,
                from: JSONEncoder().encode(projected)), projected)
        }
    }),
    ("usage DTO distinguishes exact total from partial breakdown and missing cost", {
        let partial = Usage(finality: .finalReport, accounted: ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 100, outputTokens: 20, cacheReadTokens: 30,
                reportedTotalTokens: 120, inputAccounting: .cacheInclusive),
            model: usageCompletenessModel(cacheWrite: nil)))
        XCTAssertEqual(partial.totalTokens, 120)
        XCTAssertTrue(partial.isTokenTotalComplete)
        XCTAssertEqual(partial.completeness.breakdown, .lowerBound)
        XCTAssertFalse(partial.isCostComplete)

        let missing = Usage(finality: .finalReport, accounted: ProviderUsage.account(
            report: nil, model: usageCompletenessModel()))
        XCTAssertEqual(missing.totalTokens, 0)
        XCTAssertEqual(missing.cost.total, 0)
        XCTAssertEqual(missing.completeness.tokenTotal, .unavailable)
        XCTAssertEqual(missing.completeness.cost, .unavailable)
        XCTAssertFalse(missing.isEmpty)
    }),
    ("usage DTO metadata survives Codable and transcript rows without metadata stay unclassified", {
        let original = Usage(finality: .finalReport, accounted: ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 8, outputTokens: 2, cacheReadTokens: 1,
                cacheWriteTokens: 1, reportedTotalTokens: 10,
                inputAccounting: .cacheInclusive),
            model: usageCompletenessModel()))
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Usage.self, from: encoded), original)

        let old = Usage(json: try XCTUnwrap(JSONValue.parse(Data(
            "{\"input\":8,\"output\":2,\"cacheRead\":1,\"cacheWrite\":1,\"totalTokens\":10}"
                .utf8))))
        XCTAssertEqual(old.input, 8)
        XCTAssertEqual(old.totalTokens, 10)
        XCTAssertEqual(old.completeness, .unclassified)
        XCTAssertFalse(old.isTokenTotalComplete)
        XCTAssertFalse(old.isCostComplete)
    }),
    ("usage DTO completeness survives transcript writer and parser", {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-usage-completeness-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = Usage(finality: .finalReport, accounted: ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 12, outputTokens: 3, cacheReadTokens: 2,
                cacheWriteTokens: 1, reportedTotalTokens: 15,
                inputAccounting: .cacheInclusive),
            model: usageCompletenessModel()))
        let writer = try SessionWriter(
            home: AgentHome(root: root), cwd: "/tmp", model: usageCompletenessModel())
        _ = try await writer.appendAssistant(
            text: "bounded answer", thinking: "", toolCalls: [], usage: usage,
            stopReason: "stop")
        await writer.close()

        let bytes = try Data(contentsOf: writer.fileURL)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\"completeness\""))
        let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(transcript.usage, usage)
    }),
    ("usage DTO saturates aggregate overflow and marks it incomplete", {
        var first = Usage()
        first.input = Int.max
        first.totalTokens = Int.max
        first.cost.input = Double.greatestFiniteMagnitude
        first.cost.total = Double.greatestFiniteMagnitude
        first.completeness = Usage.CompletenessMetadata(
            tokenTotal: .complete, breakdown: .complete, cost: .complete,
            inputAccounting: .cacheExclusive)
        var second = Usage()
        second.input = 1
        second.totalTokens = 1
        second.cost.input = Double.greatestFiniteMagnitude
        second.cost.total = Double.greatestFiniteMagnitude
        second.completeness = Usage.CompletenessMetadata(
            tokenTotal: .complete, breakdown: .complete, cost: .complete,
            inputAccounting: .cacheExclusive)

        let total = first + second
        XCTAssertEqual(total.input, Int.max)
        XCTAssertEqual(total.totalTokens, Int.max)
        XCTAssertEqual(total.cost.total, Double.greatestFiniteMagnitude)
        XCTAssertEqual(total.completeness.tokenTotal, .lowerBound)
        XCTAssertEqual(total.completeness.breakdown, .lowerBound)
        XCTAssertEqual(total.completeness.cost, .lowerBound)
    }),
    ("usage owned Codable rejects invalid numbers and completeness claims", {
        var negative = Usage()
        negative.input = -1
        negative.completeness = .unclassified
        XCTAssertTrue(usageEncodingFails(negative))

        var nonfinite = Usage()
        nonfinite.cost.input = .infinity
        nonfinite.cost.total = .infinity
        nonfinite.completeness = .unclassified
        XCTAssertTrue(usageEncodingFails(nonfinite))

        var numericNeutral = Usage()
        numericNeutral.input = 1
        numericNeutral.totalTokens = 1
        XCTAssertTrue(usageEncodingFails(numericNeutral))

        let contradictory = Data("""
        {"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,
         "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},
         "completeness":{"tokenTotal":"complete","breakdown":"complete","cost":"complete","inputAccounting":"cache_exclusive"}}
        """.utf8)
        XCTAssertTrue(usageDecodingFails(contradictory))
        let unknownAccounting = Data("""
        {"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,
         "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},
         "completeness":{"tokenTotal":"complete","breakdown":"complete","cost":"complete","inputAccounting":"unknown"}}
        """.utf8)
        XCTAssertTrue(usageDecodingFails(unknownAccounting))

        let completeBelowKnownFloor = Data("""
        {"input":2,"output":1,"cacheRead":1,"cacheWrite":0,"totalTokens":3,
         "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},
         "completeness":{"tokenTotal":"complete","breakdown":"lower_bound","cost":"complete","inputAccounting":"cache_exclusive"}}
        """.utf8)
        XCTAssertTrue(usageDecodingFails(completeBelowKnownFloor))

        let contradictoryCost = Data("""
        {"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,
         "cost":{"input":1,"output":0,"cacheRead":0,"cacheWrite":0,"total":2},
         "completeness":{"tokenTotal":"complete","breakdown":"complete","cost":"complete","inputAccounting":"cache_exclusive"}}
        """.utf8)
        XCTAssertTrue(usageDecodingFails(contradictoryCost))

        let hiddenTinyCost = Data("""
        {"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,
         "cost":{"input":0.0000000000001,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},
         "completeness":{"tokenTotal":"complete","breakdown":"complete","cost":"complete","inputAccounting":"cache_exclusive"}}
        """.utf8)
        XCTAssertTrue(usageDecodingFails(hiddenTinyCost))

        let missingOwnedEvidence = Data("""
        {"input":2,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":3,
         "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}
        """.utf8)
        XCTAssertTrue(usageDecodingFails(missingOwnedEvidence))

        var invalidCost = Usage.Cost()
        invalidCost.output = -.infinity
        XCTAssertTrue(costEncodingFails(invalidCost))
        let negativeCost = Data(
            "{\"input\":0,\"output\":-1,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}".utf8)
        XCTAssertTrue(costDecodingFails(negativeCost))
    }),
    ("usage transcript import sanitizes malformed values without inventing evidence", {
        let imported = Usage(json: .object([
            "input": .number(-4),
            "output": .number(7),
            "cacheRead": .string("not-an-integer"),
            "cacheWrite": .number(2),
            "reasoning": .number(9),
            "totalTokens": .string("bad-total"),
            "cost": .object([
                "input": .number(1), "output": .number(-2),
                "cacheRead": .number(.infinity), "cacheWrite": .number(0),
                "total": .number(.nan),
            ]),
        ]))
        XCTAssertEqual(imported.input, 0)
        XCTAssertEqual(imported.output, 7)
        XCTAssertEqual(imported.cacheRead, 0)
        XCTAssertEqual(imported.cacheWrite, 2)
        XCTAssertNil(imported.reasoning)
        XCTAssertEqual(imported.totalTokens, 0)
        XCTAssertEqual(imported.cost.input, 1)
        XCTAssertEqual(imported.cost.output, 0)
        XCTAssertEqual(imported.cost.cacheRead, 0)
        XCTAssertEqual(imported.cost.total, 0)
        XCTAssertEqual(imported.completeness, .unclassified)
        XCTAssertFalse(imported.isEmpty)
        XCTAssertFalse(usageEncodingFails(imported))

        let missing = Usage(json: .object(["input": .number(5)]))
        XCTAssertEqual(missing.input, 5)
        XCTAssertEqual(missing.totalTokens, 5)
        XCTAssertEqual(missing.completeness, .unclassified)

        let forgedCompleteWithoutCost = Usage(json: .object([
            "input": .number(1), "output": .number(0),
            "cacheRead": .number(0), "cacheWrite": .number(0),
            "totalTokens": .number(1),
            "completeness": .object([
                "tokenTotal": .string("complete"), "breakdown": .string("complete"),
                "cost": .string("complete"),
                "inputAccounting": .string("cache_exclusive"),
            ]),
        ]))
        XCTAssertEqual(forgedCompleteWithoutCost.completeness, .unclassified)

        let forgedCompleteWithCoercedCost = Usage(json: .object([
            "input": .number(1), "output": .number(0),
            "cacheRead": .number(0), "cacheWrite": .number(0),
            "totalTokens": .number(1),
            "cost": .object([
                "input": .bool(true), "output": .number(0),
                "cacheRead": .number(0), "cacheWrite": .number(0),
                "total": .number(1),
            ]),
            "completeness": .object([
                "tokenTotal": .string("complete"), "breakdown": .string("complete"),
                "cost": .string("complete"),
                "inputAccounting": .string("cache_exclusive"),
            ]),
        ]))
        XCTAssertEqual(forgedCompleteWithCoercedCost.cost.input, 0)
        XCTAssertEqual(forgedCompleteWithCoercedCost.completeness, .unclassified)

        let importedStringCost = Usage(json: .object([
            "input": .number(1), "output": .number(0),
            "cacheRead": .number(0), "cacheWrite": .number(0),
            "totalTokens": .number(1),
            "cost": .object([
                "input": .string("1.25"), "output": .number(0),
                "cacheRead": .number(0), "cacheWrite": .number(0),
                "total": .number(1.25),
            ]),
            "completeness": .object([
                "tokenTotal": .string("complete"), "breakdown": .string("complete"),
                "cost": .string("complete"),
                "inputAccounting": .string("cache_exclusive"),
            ]),
        ]))
        XCTAssertEqual(importedStringCost.cost.input, 1.25)
        XCTAssertEqual(importedStringCost.completeness, .unclassified)
    }),
    ("known zero cost is explicitly persisted and remains complete", {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-usage-known-zero-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = Usage(finality: .finalReport, accounted: ProviderUsage.account(
            report: ProviderUsage.RawReport(
                inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                cacheWriteTokens: 0, reportedTotalTokens: 0,
                inputAccounting: .cacheExclusive),
            model: usageCompletenessModel()))
        XCTAssertTrue(usage.isCostComplete)
        XCTAssertEqual(usage.cost.total, 0)
        let writer = try SessionWriter(
            home: AgentHome(root: root), cwd: "/tmp", model: usageCompletenessModel())
        _ = try await writer.appendAssistant(
            text: "zero", thinking: "", toolCalls: [], usage: usage, stopReason: "stop")
        await writer.close()

        let bytes = try Data(contentsOf: writer.fileURL)
        let entries = bytes.split(separator: UInt8(ascii: "\n")).compactMap {
            JSONValue.parse(Data($0))
        }
        let assistant = entries.first { $0.path("message.role")?.stringValue == "assistant" }
        XCTAssertNotNil(assistant?.path("message.usage.cost")?.objectValue)
        let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertTrue(transcript.usage.isCostComplete)
        XCTAssertEqual(transcript.usage.cost.total, 0)
    }),
    ("explicit neutral transcript usage becomes a visible unclassified crossing", {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-usage-neutral-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SessionWriter(
            home: AgentHome(root: root), cwd: "/tmp", model: usageCompletenessModel())
        _ = try await writer.appendAssistant(
            text: "neutral", thinking: "", toolCalls: [], usage: Usage(), stopReason: "stop")
        await writer.close()
        let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(transcript.usage.completeness, .unclassified)
        XCTAssertFalse(transcript.usage.isEmpty)
    }),
    ("usage transcript preserves integers beyond the exact JSON double range", {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-usage-large-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = 9_007_199_254_740_993
        var usage = Usage()
        usage.input = exact
        usage.totalTokens = exact
        usage.completeness = Usage.CompletenessMetadata(
            tokenTotal: .complete, breakdown: .complete, cost: .complete,
            inputAccounting: .cacheExclusive)
        let writer = try SessionWriter(
            home: AgentHome(root: root), cwd: "/tmp", model: usageCompletenessModel())
        _ = try await writer.appendAssistant(
            text: "large", thinking: "", toolCalls: [], usage: usage, stopReason: "stop")
        await writer.close()

        let bytes = try Data(contentsOf: writer.fileURL)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(
            "\"input\":\"9007199254740993\""))
        let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(transcript.usage.input, exact)
        XCTAssertEqual(transcript.usage.totalTokens, exact)
        let owned = try JSONDecoder().decode(
            Usage.self, from: JSONEncoder().encode(transcript.usage))
        XCTAssertEqual(owned.input, exact)
        XCTAssertEqual(owned.totalTokens, exact)
    }),
    ("missing child usage remains visible as an unclassified crossing", {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-child-usage-missing-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = AgentHome(root: root)
        let writer = try SessionWriter(
            home: home, cwd: "/tmp", model: usageCompletenessModel())
        await writer.close()
        let handle = try FileHandle(forWritingTo: writer.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"type":"child_usage_attributed","id":"missing-child-usage","timestamp":"2026-09-12T00:00:00.000Z"}

        """.utf8))
        try handle.synchronize()
        try handle.close()

        let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(transcript.childUsage.completeness, .unclassified)
        XCTAssertFalse(transcript.childUsage.isEmpty)
        #if !os(Linux)
        let catalog = SessionCatalog(home: home)
        let rows = await catalog.scan()
        let row = try XCTUnwrap(rows.first { $0.fileURL?.lastPathComponent == writer.fileURL.lastPathComponent })
        XCTAssertEqual(row.childUsage.completeness, .unclassified)
        XCTAssertFalse(row.childUsage.isEmpty)
        #endif
    }),
    ("compaction context count is unclassified rather than provider usage", {
        let data = Data("""
        {"type":"session","id":"usage-compaction","timestamp":"2026-09-12T00:00:00.000Z","cwd":"/tmp"}
        {"type":"compaction","id":"compact","parentId":"usage-compaction","timestamp":"2026-09-12T00:00:01.000Z","summary":"summary","tokensBefore":42}

        """.utf8)
        let transcript = try XCTUnwrap(SessionParser.parse(data: data, fallbackID: "usage-compaction"))
        let compaction = try XCTUnwrap(transcript.items.first { $0.kind == .compaction })
        XCTAssertEqual(compaction.usage?.totalTokens, 42)
        XCTAssertEqual(compaction.usage?.completeness, .unclassified)
        XCTAssertFalse(compaction.usage?.isTokenTotalComplete ?? true)
    }),
]

private func usageEncodingFails(_ usage: Usage) -> Bool {
    do {
        _ = try JSONEncoder().encode(usage)
        return false
    } catch {
        return true
    }
}

private func usageDecodingFails(_ data: Data) -> Bool {
    do {
        _ = try JSONDecoder().decode(Usage.self, from: data)
        return false
    } catch {
        return true
    }
}

private func costEncodingFails(_ cost: Usage.Cost) -> Bool {
    do {
        _ = try JSONEncoder().encode(cost)
        return false
    } catch {
        return true
    }
}

private func costDecodingFails(_ data: Data) -> Bool {
    do {
        _ = try JSONDecoder().decode(Usage.Cost.self, from: data)
        return false
    } catch {
        return true
    }
}

private func usageCompletenessModel(
    input: Double? = 2, output: Double? = 4,
    cacheRead: Double? = 0.5, cacheWrite: Double? = 1
) -> ModelSpec {
    var model = ModelSpec(rpc: .object([
        "id": .string("usage-completeness-model"),
        "provider": .string("usage-completeness-provider"),
    ]))
    model.costInput = input
    model.costOutput = output
    model.costCacheRead = cacheRead
    model.costCacheWrite = cacheWrite
    return model
}
