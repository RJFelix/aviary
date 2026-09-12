import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

@testable import AviaryCore

private enum RuntimeTelemetryHostVariant: String, CaseIterable, Sendable {
    case reference = "python3"
    case shared = "python3-shared"
}

private struct RuntimeTelemetryCallbackObservation: Sendable, Equatable {
    let kind: String
    let marker: String?
    let payloadContainedTraceparent: Bool
}

private actor RuntimeTelemetryCallbackLog {
    private var observations: [RuntimeTelemetryCallbackObservation] = []

    func record(kind: String, payload: JSONValue) {
        observations.append(RuntimeTelemetryCallbackObservation(
            kind: kind,
            marker: payload["marker"]?.stringValue,
            payloadContainedTraceparent: payload["traceparent"] != nil))
    }

    func waitFor(kind: String? = nil, marker: String? = nil) async throws {
        for _ in 0..<300 {
            if observations.contains(where: {
                (kind == nil || $0.kind == kind) && (marker == nil || $0.marker == marker)
            }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(
            domain: "RuntimeHostTelemetryTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "runtime callback was not observed within 3 seconds"])
    }

    var snapshot: [RuntimeTelemetryCallbackObservation] { observations }
}

private func withRuntimeTelemetryHost<Value: Sendable>(
    _ variant: RuntimeTelemetryHostVariant,
    operation: @Sendable (RuntimeHost) async throws -> Value
) async throws -> Value? {
    guard let root = EngineLocator.repoRoot() else {
        print("      skipped: no repo root found")
        return nil
    }
    let script = root.appending(path: "runtime-hosts/\(variant.rawValue)/host.py")
    guard FileManager.default.fileExists(atPath: script.path) else {
        print("      skipped: \(variant.rawValue) host missing")
        return nil
    }
    let host = RuntimeHost(
        executable: "/usr/bin/env", arguments: ["python3", script.path],
        parentLifetimeLease: true)
    do {
        _ = try await host.start()
        let value = try await operation(host)
        await host.stop()
        return value
    } catch {
        await host.stop()
        throw error
    }
}

private func installRuntimeTelemetryCallbackHandler(
    on host: RuntimeHost, log: RuntimeTelemetryCallbackLog
) async {
    await host.onCallback { _, _, kind, payload in
        await AviaryTelemetry.withSpan("aviary.test.runtime.callback_consumer") {
            await log.record(kind: kind, payload: payload)
            return payload
        }
    }
}

private func runtimeTelemetryGateURL(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
        path: "rtp-\(label)-\(String(UUID().uuidString.lowercased().prefix(8)))")
}

private func waitForRuntimeTelemetryFile(_ url: URL) async throws {
    for _ in 0..<300 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "RuntimeHostTelemetryTests", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "runtime gate was not observed within 3 seconds"])
}

private func executeSpan(
    in spans: [SpanData], beneath root: SpanData
) throws -> SpanData {
    try XCTUnwrap(spans.first {
        $0.name == "aviary.runtime.execute" && $0.parentSpanId == root.spanId
    })
}

private func assertCallbackChain(
    spans: [SpanData], execute: SpanData, expectedCount: Int, line: Int = #line
) {
    let callbacks = spans.filter {
        $0.name == "aviary.runtime.callback" && $0.traceId == execute.traceId
    }
    XCTAssertEqual(callbacks.count, expectedCount, line: line)
    for callback in callbacks {
        XCTAssertEqual(callback.kind, .server, line: line)
        XCTAssertEqual(callback.parentSpanId, execute.spanId, line: line)
        XCTAssertEqual(callback.attributes["aviary.outcome"], .string("completed"), line: line)
        XCTAssertEqual(
            callback.attributes["aviary.runtime.session.id"],
            execute.attributes["aviary.runtime.session.id"], line: line)
        XCTAssertNotNil(callback.attributes["aviary.request.id"], line: line)
        let reply = callback.events.first { $0.name == "aviary.runtime.callback.reply" }
        XCTAssertEqual(
            reply?.attributes["aviary.runtime.callback.reply_state"],
            .string("accepted"), line: line)
    }
    let callbackIDs = Set(callbacks.map(\.spanId))
    let consumers = spans.filter {
        $0.name == "aviary.test.runtime.callback_consumer"
            && $0.traceId == execute.traceId
    }
    XCTAssertEqual(consumers.count, expectedCount, line: line)
    XCTAssertTrue(
        consumers.allSatisfy { consumer in
            consumer.parentSpanId.map(callbackIDs.contains) == true
        },
        "callback consumer escaped its explicit server span", line: line)
}

private func test_runtimeTelemetryConcurrentSessions(
    variant: RuntimeTelemetryHostVariant
) async throws {
    _ = try await withRuntimeTelemetryHost(variant) { host in
        let log = RuntimeTelemetryCallbackLog()
        await installRuntimeTelemetryCallbackHandler(on: host, log: log)
        let firstSession = try await host.createSession(
            id: "rtp-a-\(String(UUID().uuidString.lowercased().prefix(8)))")
        let secondSession = try await host.createSession(
            id: "rtp-b-\(String(UUID().uuidString.lowercased().prefix(8)))")

        let ((first, second), spans) = try await AviaryTelemetry.withRecording {
            async let first = AviaryTelemetry.withSpan(
                "aviary.test.runtime.root_a", root: true
            ) {
                try await host.execute(
                    "ask_app('trace_probe', marker='private-a')", in: firstSession, timeout: 5)
            }
            async let second = AviaryTelemetry.withSpan(
                "aviary.test.runtime.root_b", root: true
            ) {
                try await host.execute(
                    "ask_app('trace_probe', marker='private-b')", in: secondSession, timeout: 5)
            }
            let results = try await (first, second)
            try await host.waitUntilCallbacksQuiescent()
            return results
        }
        XCTAssertNil(first.exception)
        XCTAssertNil(second.exception)
        XCTAssertTrue(first.value?.contains("private-a") == true)
        XCTAssertTrue(second.value?.contains("private-b") == true)
        let observed = await log.snapshot
        XCTAssertEqual(Set(observed.compactMap(\.marker)), Set(["private-a", "private-b"]))
        XCTAssertTrue(observed.allSatisfy { !$0.payloadContainedTraceparent })

        let rootA = try XCTUnwrap(spans.first { $0.name == "aviary.test.runtime.root_a" })
        let rootB = try XCTUnwrap(spans.first { $0.name == "aviary.test.runtime.root_b" })
        XCTAssertNotEqual(rootA.traceId, rootB.traceId)
        let executeA = try executeSpan(in: spans, beneath: rootA)
        let executeB = try executeSpan(in: spans, beneath: rootB)
        assertCallbackChain(spans: spans, execute: executeA, expectedCount: 1)
        assertCallbackChain(spans: spans, execute: executeB, expectedCount: 1)
        XCTAssertFalse(String(describing: spans).contains("private-a"))
        XCTAssertFalse(String(describing: spans).contains("private-b"))
    }
}

private func test_runtimeTelemetryReferenceFutureRetainsOrigin() async throws {
    _ = try await withRuntimeTelemetryHost(.reference) { host in
        let log = RuntimeTelemetryCallbackLog()
        await installRuntimeTelemetryCallbackHandler(on: host, log: log)
        let session = try await host.createSession(
            id: "rtp-future-\(String(UUID().uuidString.lowercased().prefix(8)))")
        let gate = runtimeTelemetryGateURL("future")
        defer { try? FileManager.default.removeItem(at: gate) }

        let (_, spans) = try await AviaryTelemetry.withRecording {
            let first = try await AviaryTelemetry.withSpan(
                "aviary.test.runtime.future_a", root: true
            ) {
                try await host.execute(
                    "old = sh(\"i=0; while [ ! -e '\(gate.path)' ] && [ $i -lt 250 ]; do sleep 0.02; i=$((i+1)); done; printf old\").notify('old')\n'armed'",
                    in: session, timeout: 5)
            }
            XCTAssertNil(first.exception)
            try await log.waitFor(kind: "dispatched")

            let second = try await AviaryTelemetry.withSpan(
                "aviary.test.runtime.future_b", root: true
            ) {
                try await host.execute("'new-cell'", in: session, timeout: 5)
            }
            XCTAssertNil(second.exception)
            XCTAssertTrue(FileManager.default.createFile(atPath: gate.path, contents: Data()))
            try await log.waitFor(kind: "notify")
            try await host.waitUntilCallbacksQuiescent()
        }

        let rootA = try XCTUnwrap(spans.first { $0.name == "aviary.test.runtime.future_a" })
        let rootB = try XCTUnwrap(spans.first { $0.name == "aviary.test.runtime.future_b" })
        let executeA = try executeSpan(in: spans, beneath: rootA)
        let executeB = try executeSpan(in: spans, beneath: rootB)
        assertCallbackChain(spans: spans, execute: executeA, expectedCount: 2)
        assertCallbackChain(spans: spans, execute: executeB, expectedCount: 0)
    }
}

private func test_runtimeTelemetrySharedCallableRetainsOrigin() async throws {
    _ = try await withRuntimeTelemetryHost(.shared) { host in
        let log = RuntimeTelemetryCallbackLog()
        await installRuntimeTelemetryCallbackHandler(on: host, log: log)
        let session = try await host.createSession(
            id: "rtp-shared-\(String(UUID().uuidString.lowercased().prefix(8)))")
        let gate = runtimeTelemetryGateURL("shared")
        defer { try? FileManager.default.removeItem(at: gate) }

        let (_, spans) = try await AviaryTelemetry.withRecording {
            let first = try await AviaryTelemetry.withSpan(
                "aviary.test.runtime.shared_a", root: true
            ) {
                try await host.execute(
                    """
                    import os, threading, time
                    origin_call = ask_app
                    def emit_old(call=origin_call):
                        deadline = time.monotonic() + 5
                        while not os.path.exists('\(gate.path)') and time.monotonic() < deadline:
                            time.sleep(0.02)
                        call('trace_probe', marker='old-shared')
                    old_thread = threading.Thread(target=emit_old)
                    old_thread.start()
                    'armed'
                    """,
                    in: session, timeout: 5)
            }
            XCTAssertNil(first.exception)

            let second = try await AviaryTelemetry.withSpan(
                "aviary.test.runtime.shared_b", root: true
            ) {
                try await host.execute(
                    "ask_app('trace_probe', marker='new-shared')", in: session, timeout: 5)
            }
            XCTAssertNil(second.exception)
            XCTAssertTrue(FileManager.default.createFile(atPath: gate.path, contents: Data()))
            try await log.waitFor(marker: "old-shared")
            try await host.waitUntilCallbacksQuiescent()
        }

        let rootA = try XCTUnwrap(spans.first { $0.name == "aviary.test.runtime.shared_a" })
        let rootB = try XCTUnwrap(spans.first { $0.name == "aviary.test.runtime.shared_b" })
        let executeA = try executeSpan(in: spans, beneath: rootA)
        let executeB = try executeSpan(in: spans, beneath: rootB)
        assertCallbackChain(spans: spans, execute: executeA, expectedCount: 1)
        assertCallbackChain(spans: spans, execute: executeB, expectedCount: 1)
    }
}

private func test_runtimeTelemetryMissingContextDoesNotInheritAttach(
    variant: RuntimeTelemetryHostVariant
) async throws {
    _ = try await withRuntimeTelemetryHost(variant) { host in
        let log = RuntimeTelemetryCallbackLog()
        await installRuntimeTelemetryCallbackHandler(on: host, log: log)
        let session = try await host.createSession(
            id: "rtp-replay-\(String(UUID().uuidString.lowercased().prefix(8)))")
        let gate = runtimeTelemetryGateURL("replay")
        let ready = runtimeTelemetryGateURL("ready")
        defer {
            try? FileManager.default.removeItem(at: gate)
            try? FileManager.default.removeItem(at: ready)
        }

        // This execution deliberately runs outside withRecording. Its retained callable has no
        // traceparent; delivery across detach/attach cannot borrow the later attach span.
        let armed = try await host.execute(
            """
            import os, threading, time
            origin_call = ask_app
            def emit_untraced(call=origin_call):
                deadline = time.monotonic() + 5
                while not os.path.exists('\(gate.path)') and time.monotonic() < deadline:
                    time.sleep(0.02)
                open('\(ready.path)', 'w').close()
                call('trace_probe', marker='untraced-replay')
            replay_thread = threading.Thread(target=emit_untraced)
            replay_thread.start()
            'armed'
            """,
            in: session, timeout: 5)
        XCTAssertNil(armed.exception)
        try await host.detachSession(session)

        let (_, spans) = try await AviaryTelemetry.withRecording(waitingFor: { spans in
            guard let consumer = spans.first(where: {
                $0.name == "aviary.test.runtime.callback_consumer"
            }) else { return false }
            return spans.contains { $0.spanId == consumer.parentSpanId }
        }) {
            // Record before releasing the producer. `ready` precedes callback registration,
            // so this covers both a pending replay and a callback registered after attach;
            // it does not claim to distinguish those two valid delivery paths.
            XCTAssertTrue(FileManager.default.createFile(atPath: gate.path, contents: Data()))
            try await waitForRuntimeTelemetryFile(ready)
            try await AviaryTelemetry.withSpan("aviary.test.runtime.attach", root: true) {
                XCTAssertTrue(try await host.attachSession(session))
                try await log.waitFor(marker: "untraced-replay")
                try await host.waitUntilCallbacksQuiescent()
            }
        }
        let attach = try XCTUnwrap(spans.first { $0.name == "aviary.test.runtime.attach" })
        let consumers = spans.filter { $0.name == "aviary.test.runtime.callback_consumer" }
        XCTAssertEqual(consumers.count, 1)
        let consumer = try XCTUnwrap(consumers.first)
        // Reattachment may race a queued unsolicited frame with its replay. Duplicate
        // exchanges have their own roots; identify the one that actually invoked the handler.
        let callback = try XCTUnwrap(spans.first {
            $0.name == "aviary.runtime.callback" && $0.spanId == consumer.parentSpanId
        })
        XCTAssertEqual(callback.kind, .server)
        XCTAssertNil(callback.parentSpanId)
        XCTAssertNotEqual(callback.traceId, attach.traceId)
        XCTAssertEqual(callback.attributes["aviary.outcome"], .string("completed"))
        XCTAssertNotNil(callback.attributes["aviary.runtime.session.id"])
        XCTAssertNotNil(callback.attributes["aviary.request.id"])
        let reply = try XCTUnwrap(callback.events.first {
            $0.name == "aviary.runtime.callback.reply"
        })
        XCTAssertEqual(
            reply.attributes["aviary.runtime.callback.reply_state"], .string("accepted"))
        XCTAssertEqual(consumer.traceId, callback.traceId)
        XCTAssertEqual(consumer.parentSpanId, callback.spanId)
        for exchange in spans where exchange.name == "aviary.runtime.callback" {
            XCTAssertNil(exchange.parentSpanId)
            XCTAssertNotEqual(exchange.traceId, attach.traceId)
        }
    }
}

let casesRuntimeHostTelemetry: [Case] = [
    ("telemetry runtime: EOF and explicit stop remain quiescent across restart", {
        for variant in RuntimeTelemetryHostVariant.allCases {
            _ = try await withRuntimeTelemetryHost(variant) { host in
                for iteration in 0..<4 {
                    if iteration > 0 { _ = try await host.start() }
                    let session = try await host.createSession(id: "eof-stop-\(iteration)")
                    let result = try await host.execute("6 * 7", in: session, timeout: 5)
                    XCTAssertNil(result.exception)
                    XCTAssertEqual(result.value, "42")
                    // The shutdown reply and peer EOF can reach the output pump while stop
                    // closes its transport. This exercises the real socket on both platforms.
                    let receipt = await host.stopWithReceipt()
                    XCTAssertTrue(receipt.ownedProcessExitVerified)
                    XCTAssertTrue(receipt.callbacksQuiescent)
                    XCTAssertFalse(await host.isRunning)
                }
            }
        }
    }),
    ("telemetry runtime: concurrent sessions keep callback parents isolated", {
        for variant in RuntimeTelemetryHostVariant.allCases {
            try await test_runtimeTelemetryConcurrentSessions(variant: variant)
        }
    }),
    ("telemetry runtime: reference Future callback retains its originating execution", {
        try await test_runtimeTelemetryReferenceFutureRetainsOrigin()
    }),
    ("telemetry runtime: shared retained callable keeps its originating execution", {
        try await test_runtimeTelemetrySharedCallableRetainsOrigin()
    }),
    ("telemetry runtime: no-context callback across detach/attach ignores the attach task", {
        for variant in RuntimeTelemetryHostVariant.allCases {
            try await test_runtimeTelemetryMissingContextDoesNotInheritAttach(
                variant: variant)
        }
    }),
]
