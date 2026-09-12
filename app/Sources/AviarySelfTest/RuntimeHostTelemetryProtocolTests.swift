import Foundation
import OpenTelemetrySdk

@testable import AviaryCore

private let runtimeHostTelemetryTraceparent =
    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

private func runtimeHostTelemetryExecFrame(
    code: String, session: String, id: String = "av-2", traceparent: String? = nil
) throws -> Data {
    var object: [String: JSONValue] = [
        "id": .string(id),
        "op": .string("exec"),
        "session": .string(session),
        "code": .string(code),
        "mode": .string("exec"),
    ]
    if let traceparent { object["traceparent"] = .string(traceparent) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var frame = try encoder.encode(JSONValue.object(object))
    frame.append(UInt8(ascii: "\n"))
    return frame
}

private func runtimeHostTelemetryExactExecCode(session: String) throws -> String {
    let target = RuntimeHost.maxFrameBytes
    // The only variable bytes are ASCII `x` characters inside a JSON string, so measuring the
    // one-byte comment prefix avoids repeatedly encoding multi-megabyte candidates.
    let prefixSize = try runtimeHostTelemetryExecFrame(code: "#", session: session).count
    let result = "#" + String(repeating: "x", count: target - prefixSize)
    guard try runtimeHostTelemetryExecFrame(code: result, session: session).count == target else {
        throw NSError(
            domain: "RuntimeHostTelemetryProtocolTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not land on the exact frame boundary"])
    }
    return result
}

private func runtimeHostTelemetryEvent(
    _ span: SpanData, name: String
) -> Bool {
    span.events.contains { $0.name == name }
}

private actor RuntimeHostTelemetryCallbackGate {
    private var received = false

    func markReceived() { received = true }

    func wait() async throws {
        for _ in 0..<200 {
            if received { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(
            domain: "RuntimeHostTelemetryProtocolTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "callback was not admitted within 2 seconds"])
    }
}

private struct RuntimeHostTelemetryCallbackObservation: Sendable {
    let kind: String
    let payload: JSONValue
}

private final class RuntimeHostTelemetryCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [RuntimeHostTelemetryCallbackObservation] = []

    func record(kind: String, payload: JSONValue) {
        lock.lock()
        observations.append(RuntimeHostTelemetryCallbackObservation(kind: kind, payload: payload))
        lock.unlock()
    }

    var snapshot: [RuntimeHostTelemetryCallbackObservation] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }
}

private func runtimeHostTelemetryWaitForSocket(_ path: String) async throws {
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: path) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "RuntimeHostTelemetryProtocolTests", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "probe socket was not created within 2 seconds"])
}

private func runtimeHostTelemetryWaitForFile(_ url: URL) async throws {
    for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "RuntimeHostTelemetryProtocolTests", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "gated shell worker did not finish within 5 seconds"])
}

private func runtimeHostTelemetryPythonLiteral<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func launchMalformedRuntimeCallbackHost(
    endpoint: RuntimeHost.SocketEndpoint, identity: RuntimeHost.HostIdentity
) throws -> Process {
    let source = #"""
import json, os, socket, sys
path, host_id, instance_id = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
os.chmod(path, 0o600)
server.settimeout(3)
server.listen(1)
connection, _ = server.accept()
connection.settimeout(3)
reader = connection.makefile("rb")
connection.sendall((json.dumps({
    "event": "ready", "protocol": 3, "runtime": "telemetry-probe",
    "runtimeVersion": "test", "hostID": host_id, "instanceID": instance_id,
    "transport": "unix", "features": {"callbacks": True},
}) + "\n").encode())
connection.sendall((json.dumps({
    "event": "callback", "rid": "malformed-context", "kind": "trace_probe",
    "payload": {"marker": "callback-delivered"}, "session": "probe-session",
    "traceparent": "not-a-traceparent",
}) + "\n").encode())
reply = reader.readline()
if reply:
    message = json.loads(reply)
    connection.sendall((json.dumps({
        "id": message.get("id"), "ok": True,
        "data": {"delivered": True, "status": "accepted"},
    }) + "\n").encode())
connection.close()
server.close()
"""#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", "-c", source, endpoint.path, identity.hostID, identity.instanceID,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.environment = ProcessEnvironment.shared.snapshot
    try process.run()
    return process
}

func test_phase5RuntimeHostTelemetryExecFrameBoundary() async throws {
    for variant in [HostVariant.reference, .shared] {
        guard let host = try makeHost(variant) else { continue }
        do {
            _ = try await host.start()
            let session = try await host.createSession(id: "telemetry-boundary-\(variant.rawValue)")
            let exactCode = try runtimeHostTelemetryExactExecCode(session: session)
            let baseFrame = try runtimeHostTelemetryExecFrame(code: exactCode, session: session)
            let tracedFrame = try runtimeHostTelemetryExecFrame(
                code: exactCode, session: session, traceparent: runtimeHostTelemetryTraceparent)
            XCTAssertEqual(baseFrame.count, RuntimeHost.maxFrameBytes)
            XCTAssertTrue(tracedFrame.count > baseFrame.count)

            let (_, spans) = try await AviaryTelemetry.withRecording {
                let result = try await AviaryTelemetry.withSpan(
                    "aviary.test.runtime.boundary", root: true
                ) {
                    try await host.execute(exactCode, in: session, timeout: 8)
                }
                XCTAssertNil(result.exception)

                do {
                    _ = try await host.execute(exactCode + "x", in: session, timeout: 2)
                    XCTFail("base-plus-one request unexpectedly fit the frame")
                } catch let error as RuntimeHost.HostError {
                    guard case .frameTooLarge(let op, let bytes, let limit) = error else {
                        XCTFail("unexpected base-plus-one error: \(error)")
                        return
                    }
                    XCTAssertEqual(op, "exec")
                    XCTAssertTrue(bytes > limit)
                    XCTAssertEqual(limit, RuntimeHost.maxFrameBytes)
                }

                let healthy = try await host.execute("40 + 2", in: session, timeout: 2)
                XCTAssertNil(healthy.exception)
                XCTAssertEqual(healthy.value, "42")
            }
            let execute = try XCTUnwrap(spans.first { $0.name == "aviary.runtime.execute" })
            XCTAssertTrue(
                runtimeHostTelemetryEvent(execute, name: "aviary.transport.context_omitted"),
                "the exact-boundary send must record that diagnostic context was omitted")
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }
}

func test_phase5RuntimeHostTelemetryMalformedCallbackContextIsIndependentRoot() async throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(
        path: "avrt-\(String(UUID().uuidString.prefix(8)).lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }

    let endpoint = RuntimeHost.SocketEndpoint(path: directory.appending(path: "host.sock").path)
    let identity = RuntimeHost.HostIdentity(hostID: "telemetry-probe", instanceID: "probe-instance")
    let process = try launchMalformedRuntimeCallbackHost(endpoint: endpoint, identity: identity)
    defer {
        if process.isRunning { process.terminate() }
    }

    let host = RuntimeHost(endpoint: endpoint, expectedIdentity: identity)
    let callbackReceived = RuntimeHostTelemetryCallbackGate()
    await host.onCallback { _, _, _, payload in
        await callbackReceived.markReceived()
        return payload
    }
    do {
        let (_, spans) = try await AviaryTelemetry.withRecording {
            try await runtimeHostTelemetryWaitForSocket(endpoint.path)
            _ = try await host.connect(timeout: 2)
            try await callbackReceived.wait()
            try await host.closeCallbackAdmissionAndWait()
        }
        let callback = try XCTUnwrap(spans.first { $0.name == "aviary.runtime.callback" })
        XCTAssertEqual(callback.kind, .server)
        XCTAssertNil(callback.parentSpanId)
        XCTAssertEqual(callback.attributes["aviary.outcome"], .string("completed"))
    } catch {
        await host.stop()
        throw error
    }
    await host.stop()
}

func test_phase5RuntimeHostTelemetrySharedCallbackConvertsArbitraryStringOnce() async throws {
    guard let host = try makeHost(.shared) else { return }
    do {
        _ = try await host.start()
        let session = try await host.createSession(id: "telemetry-shared-conversion")
        let recorder = RuntimeHostTelemetryCallbackRecorder()
        await host.onCallback { _, _, kind, payload in
            recorder.record(kind: kind, payload: payload)
            return .object(["ok": .bool(true)])
        }

        let setup = try await host.execute(
            """
            class StringCounter:
                calls = 0
                def __str__(self):
                    StringCounter.calls += 1
                    return 'converted'
            marker = StringCounter()
            """,
            in: session, timeout: 5)
        XCTAssertNil(setup.exception)

        let (_, spans) = try await AviaryTelemetry.withRecording {
            let traced = try await AviaryTelemetry.withSpan(
                "aviary.test.runtime.shared_conversion", root: true
            ) {
                try await host.execute(
                    "ask_app('trace_probe', marker=marker)", in: session, timeout: 5)
            }
            XCTAssertNil(traced.exception)
            try await host.waitUntilCallbacksQuiescent()
        }
        let untraced = try await host.execute(
            "ask_app('trace_probe', marker=marker)", in: session, timeout: 5)
        XCTAssertNil(untraced.exception)
        let count = try await host.execute("StringCounter.calls", in: session, timeout: 5)
        XCTAssertNil(count.exception)
        XCTAssertEqual(count.value, "2")

        let callbacks = recorder.snapshot
        XCTAssertEqual(callbacks.count, 2)
        XCTAssertTrue(callbacks.allSatisfy {
            $0.kind == "trace_probe" && $0.payload["marker"]?.stringValue == "converted"
        })
        XCTAssertTrue(spans.contains { $0.name == "aviary.runtime.callback" })
    } catch {
        await host.stop()
        throw error
    }
    await host.stop()
}

func test_phase5RuntimeTelemetrySharedBindingsRespectOverwriteAndDeletion() async throws {
    guard let host = try makeHost(.shared) else { return }
    do {
        _ = try await host.start()
        let session = try await host.createSession(id: "telemetry-shared-bindings")
        let overwritten = try await host.execute(
            """
            ask_app = lambda *args, **kwargs: 'user-ask'
            conversation = lambda *args, **kwargs: 'user-conversation'
            (ask_app('ignored'), conversation())
            """,
            in: session, timeout: 5)
        XCTAssertNil(overwritten.exception)
        XCTAssertEqual(overwritten.value, "('user-ask', 'user-conversation')")

        let retained = try await host.execute(
            "(ask_app('still-user'), conversation())", in: session, timeout: 5)
        XCTAssertNil(retained.exception)
        XCTAssertEqual(retained.value, "('user-ask', 'user-conversation')")

        let deleted = try await host.execute(
            "del ask_app\ndel conversation\n('ask_app' in globals(), 'conversation' in globals())",
            in: session, timeout: 5)
        XCTAssertNil(deleted.exception)
        XCTAssertEqual(deleted.value, "(False, False)")
        let stillDeleted = try await host.execute(
            "('ask_app' in globals(), 'conversation' in globals())", in: session, timeout: 5)
        XCTAssertNil(stillDeleted.exception)
        XCTAssertEqual(stillDeleted.value, "(False, False)")
    } catch {
        await host.stop()
        throw error
    }
    await host.stop()
}

func test_phase5RuntimeTelemetryReferenceFutureCallbacksKeepPublicSignatures() async throws {
    guard let host = try makeHost(.reference) else { return }
    do {
        _ = try await host.start()
        let session = try await host.createSession(id: "telemetry-reference-futures")
        let recorder = RuntimeHostTelemetryCallbackRecorder()
        await host.onCallback { _, _, kind, payload in
            recorder.record(kind: kind, payload: payload)
            return .object(["ok": .bool(true)])
        }

        let signatures = try await host.execute(
            """
            import inspect
            (str(inspect.signature(sh)), str(inspect.signature(ask_app)),
             str(inspect.signature(search)),
             str(inspect.signature(read_url)))
            """,
            in: session, timeout: 5)
        XCTAssertNil(signatures.exception)
        XCTAssertTrue(signatures.value?.contains("(command, timeout=None)") == true)
        XCTAssertTrue(signatures.value?.contains("call_app") == false)
        XCTAssertTrue(signatures.value?.contains("**payload") == true)
        XCTAssertTrue(signatures.value?.contains("**rest") == true)

        let futures = try await host.execute(
            """
            search_future = search('objective', queries=['q'], mode='fast', n=1,
                                   callback='search-callback', _call_app='search-sentinel')
            read_future = read_url('https://example.test', objective='objective', full=True,
                                   callback='read-callback', _call_app='read-sentinel')
            (search_future.result(timeout=5), read_future.result(timeout=5))
            """,
            in: session, timeout: 10)
        XCTAssertNil(futures.exception)

        let callbacks = recorder.snapshot
        XCTAssertTrue(callbacks.contains {
            $0.kind == "search"
                && $0.payload["_call_app"]?.stringValue == "search-sentinel"
                && $0.payload["callback"]?.stringValue == "search-callback"
        })
        XCTAssertTrue(callbacks.contains {
            $0.kind == "read_url"
                && $0.payload["_call_app"]?.stringValue == "read-sentinel"
                && $0.payload["callback"]?.stringValue == "read-callback"
        })
    } catch {
        await host.stop()
        throw error
    }
    await host.stop()
}

func test_phase5RuntimeTelemetryReferenceShellFutureRetainsCellState() async throws {
    guard let host = try makeHost(.reference) else { return }
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(
        path: "avsh-\(String(UUID().uuidString.prefix(8)).lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    let releaseA = directory.appending(path: "release-a")
    let releaseB = directory.appending(path: "release-b")
    let doneA = directory.appending(path: "done-a")
    let doneB = directory.appending(path: "done-b")
    let gates = try runtimeHostTelemetryPythonLiteral([releaseA.path, releaseB.path])
    let completions = try runtimeHostTelemetryPythonLiteral([doneA.path, doneB.path])
    let commandA = try runtimeHostTelemetryPythonLiteral(
        "printf 'a-start:%s\\n' \"$PWD\"; cd /usr/lib; export AVIARY_LATE_CAPTURE=A; printf a")
    let commandB = try runtimeHostTelemetryPythonLiteral(
        "printf 'b-start:%s\\n' \"$PWD\"; cd /usr/bin; export AVIARY_LATE_CAPTURE=B; printf b")

    do {
        _ = try await host.start()
        let session = try await host.createSession(
            id: "telemetry-reference-late-shell", cwd: "/tmp")
        // Hold both real shell workers until after the execution body has returned and removed
        // its per-cell names. This deterministically exercises both the launch snapshot and the
        // last-finisher state writeback without depending on thread scheduling or a sleep command.
        let launched = try await host.execute(
            """
            import os, threading, time
            _aviary_test_gates = \(gates)
            _aviary_test_completions = \(completions)
            _aviary_test_next_thread = 0
            _aviary_test_original_start = threading.Thread.start
            def _aviary_test_gated_start(thread):
                target = thread._target
                # Only the two shell-worker targets belong to this fixture. Any unrelated
                # runtime thread must retain normal startup and must not consume a gate slot.
                if getattr(target, '__name__', None) != '__aviary_run_sh':
                    _aviary_test_original_start(thread)
                    return
                global _aviary_test_next_thread
                index = _aviary_test_next_thread
                _aviary_test_next_thread += 1
                def held_target():
                    deadline = time.monotonic() + 5
                    while not os.path.exists(_aviary_test_gates[index]):
                        if time.monotonic() >= deadline:
                            raise TimeoutError('test shell gate was not released')
                        time.sleep(0.001)
                    try:
                        target()
                    finally:
                        with open(_aviary_test_completions[index], 'w'):
                            pass
                thread._target = held_target
                _aviary_test_original_start(thread)
            threading.Thread.start = _aviary_test_gated_start
            try:
                job_a = sh(\(commandA))
                job_b = sh(\(commandB))
            finally:
                threading.Thread.start = _aviary_test_original_start
            (job_a.done(), job_b.done())
            """,
            in: session, timeout: 5)
        XCTAssertNil(launched.exception, launched.exception ?? "shell launch failed")
        XCTAssertEqual(launched.value, "(False, False)")

        // B finishes first, then A. The persistent per-Session lock makes A's complete
        // writeback the final state while both commands retain the /tmp launch snapshot.
        try Data().write(to: releaseB, options: .atomic)
        try await runtimeHostTelemetryWaitForFile(doneB)
        try Data().write(to: releaseA, options: .atomic)
        try await runtimeHostTelemetryWaitForFile(doneA)

        let outputs = try await host.execute(
            "(job_a.result()['stdout'], job_b.result()['stdout'])", in: session, timeout: 5)
        XCTAssertNil(outputs.exception, outputs.exception ?? "late shell Future failed")
        XCTAssertTrue(outputs.value?.contains("a-start:/tmp\\na") == true)
        XCTAssertTrue(outputs.value?.contains("b-start:/tmp\\nb") == true)

        let cwd = try await host.execute("cwd()", in: session, timeout: 5)
        XCTAssertNil(cwd.exception)
        XCTAssertEqual(cwd.value, "'/usr/lib'")
        let environment = try await host.execute(
            "sh('printf \"$AVIARY_LATE_CAPTURE\"').result()['stdout']", in: session, timeout: 5)
        XCTAssertNil(environment.exception)
        XCTAssertEqual(environment.value, "'A'")
    } catch {
        await host.stop()
        throw error
    }
    await host.stop()
}

let casesRuntimeHostTelemetryProtocol: [Case] = [
    ("phase5 runtime telemetry: exec frame context omission preserves exact boundary", {
        try await test_phase5RuntimeHostTelemetryExecFrameBoundary()
    }),
    ("phase5 runtime telemetry: malformed callback context starts independent root", {
        try await test_phase5RuntimeHostTelemetryMalformedCallbackContextIsIndependentRoot()
    }),
    ("phase5 runtime telemetry: shared callback converts arbitrary strings once", {
        try await test_phase5RuntimeHostTelemetrySharedCallbackConvertsArbitraryStringOnce()
    }),
    ("phase5 runtime telemetry: shared bindings preserve user overwrite and deletion", {
        try await test_phase5RuntimeTelemetrySharedBindingsRespectOverwriteAndDeletion()
    }),
    ("phase5 runtime telemetry: reference Future callbacks preserve public signatures", {
        try await test_phase5RuntimeTelemetryReferenceFutureCallbacksKeepPublicSignatures()
    }),
    ("phase5 runtime telemetry: reference shell Future retains state after cell cleanup", {
        try await test_phase5RuntimeTelemetryReferenceShellFutureRetainsCellState()
    }),
]
