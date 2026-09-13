import Foundation

@testable import AviaryCore

private func workAgentSpawnPolicyThrows(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        return true
    }
}

let casesWorkAgentSpawnPolicy: [Case] = [
    ("phase5 Work agent spawn policy: omitted and null fields are unlimited", {
        let omitted = try WorkAgentSpawnPolicy(callbackPayload: .object([:]))
        XCTAssertEqual(omitted, .unlimited)
        XCTAssertEqual(omitted.callbackPayload, .object([:]))

        let explicitNull = try WorkAgentSpawnPolicy(callbackPayload: .object([
            "timeout": .null, "token_limit": .null, "cost_limit_usd": .null,
        ]))
        XCTAssertEqual(explicitNull, .unlimited)

        let complete = try WorkAgentSpawnPolicy(callbackPayload: .object([
            "prompt": .string("ordinary spawn field"),
            "name": .string("ordinary name"),
            "model": .string("ordinary model"),
            "timeout": .number(2.5),
            "token_limit": .string(String(Int.max)),
            "cost_limit_usd": .number(0.125),
        ]))
        XCTAssertEqual(complete.timeout, 2.5)
        XCTAssertEqual(complete.executionLimits.maximumTokens, Int.max)
        XCTAssertEqual(complete.executionLimits.maximumEstimatedCostUSD, 0.125)
        XCTAssertEqual(complete.callbackPayload["token_limit"], .string(String(Int.max)))
        XCTAssertEqual(complete.callbackPayload["timeout"], .number(2.5))
        XCTAssertEqual(complete.callbackPayload["cost_limit_usd"], .number(0.125))
    }),
    ("phase5 Work agent spawn policy: malformed fields fail closed", {
        let invalidPayloads: [JSONValue] = [
            .string("not an object"),
            .object(["unknown": .number(1)]),
            .object(["timeout": .bool(true)]),
            .object(["timeout": .number(0)]),
            .object(["timeout": .number(-1)]),
            .object(["timeout": .number(.infinity)]),
            .object(["token_limit": .number(1)]),
            .object(["token_limit": .string("01")]),
            .object(["token_limit": .string("+1")]),
            .object(["token_limit": .string("0")]),
            .object(["token_limit": .string("-1")]),
            .object(["cost_limit_usd": .bool(false)]),
            .object(["cost_limit_usd": .number(0)]),
            .object(["cost_limit_usd": .number(-0.5)]),
            .object(["cost_limit_usd": .number(.nan)]),
        ]
        for payload in invalidPayloads {
            XCTAssertTrue(workAgentSpawnPolicyThrows {
                _ = try WorkAgentSpawnPolicy(callbackPayload: payload)
            })
        }
    }),
    ("phase5 Work agent spawn policy: limits retain exact integer spelling", {
        let payload = JSONValue.object([
            "token_limit": .string(String(Int.max)),
        ])
        let policy = try WorkAgentSpawnPolicy(callbackPayload: payload)
        XCTAssertEqual(policy.executionLimits.maximumTokens, Int.max)
        XCTAssertEqual(policy.callbackPayload["token_limit"], .string(String(Int.max)))

        let tooLong = String(repeating: "9", count: WorkAgentExecutionLimits.maximumDecimalBytes + 1)
        XCTAssertTrue(workAgentSpawnPolicyThrows {
            _ = try WorkAgentSpawnPolicy(callbackPayload: .object([
                "token_limit": .string(tooLong),
            ]))
        })
    }),
    ("phase5 Work agent spawn policy: deadline is one bounded future", {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = try WorkAgentSpawnPolicy(callbackPayload: .object([
            "timeout": .number(10),
        ]))
        let timeoutDeadline = try XCTUnwrap(
            policy.absoluteDeadline(now: now, pilotDeadline: nil))
        XCTAssertEqual(timeoutDeadline.timeIntervalSince1970, 1_010)

        let pilotDeadline = Date(timeIntervalSince1970: 1_005)
        XCTAssertEqual(
            try policy.absoluteDeadline(now: now, pilotDeadline: pilotDeadline),
            pilotDeadline)

        let noTimeout = try WorkAgentSpawnPolicy(callbackPayload: .object([:]))
        XCTAssertEqual(
            try noTimeout.absoluteDeadline(now: now, pilotDeadline: pilotDeadline),
            pilotDeadline)
        XCTAssertNil(try noTimeout.absoluteDeadline(now: now, pilotDeadline: nil))

        XCTAssertTrue(workAgentSpawnPolicyThrows {
            _ = try policy.absoluteDeadline(now: now, pilotDeadline: now)
        })
        XCTAssertTrue(workAgentSpawnPolicyThrows {
            _ = try policy.absoluteDeadline(
                now: now, pilotDeadline: Date(timeIntervalSince1970: 999))
        })
    }),
]
