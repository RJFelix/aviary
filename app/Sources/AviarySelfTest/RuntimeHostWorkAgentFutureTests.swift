import Foundation

@testable import AviaryCore

private final class WorkFutureCallbackLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedKinds: [String] = []

    func record(_ kind: String) {
        lock.withLock { storedKinds.append(kind) }
    }

    var kinds: [String] { lock.withLock { storedKinds } }
}

private final class WorkFutureSpawnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int { lock.withLock { value += 1; return value } }
}

private actor WorkFutureInterestGate {
    private var observed = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func serve() async -> JSONValue {
        observed = true
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .object(["accepted": .bool(true)])
    }

    func waitUntilObserved(maxPolls: Int = 200) async throws {
        for _ in 0..<maxPolls {
            if observed { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(
            domain: "RuntimeHostWorkAgentFutureTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "await interest callback was not observed"])
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func workFuturePythonRoot() -> URL? {
    guard let root = EngineLocator.repoRoot(),
          FileManager.default.fileExists(
              atPath: root.appending(path: "runtime-hosts/python3/host.py").path)
    else { return nil }
    return root
}

private func withWorkFutureHost<Value: Sendable>(
    root: URL,
    body: @Sendable (RuntimeHost, String) async throws -> Value
) async throws -> Value {
    guard let host = RuntimeHost.bundledPython(repoRoot: root, parentLifetimeLease: true)
    else { throw RuntimeHost.HostError.invalidEndpoint("bundled Python host is unavailable") }
    do {
        _ = try await host.start()
        let session = try await host.createSession(
            id: "future-test-\(UUID().uuidString.lowercased())")
        let result = try await body(host, session)
        await host.stop()
        return result
    } catch {
        await host.stop()
        throw error
    }
}

private func workFutureRecord(
    id: String, deadline: Double? = Date().addingTimeInterval(60).timeIntervalSince1970,
    state: String = "terminal", outcome: String? = "succeeded"
) -> JSONValue {
    var value: [String: JSONValue] = [
        "id": .string(id),
        "name": .string("future-child"),
        "ownership": .string("work"),
        "state": .string(state),
        "deadline": deadline.map { .number($0) } ?? .null,
    ]
    if let outcome { value["outcome"] = .string(outcome) }
    return .object(value)
}

func test_runtimeHostWorkFuturePreservesAdmittedAndUncertainIDs() async throws {
    guard let root = workFuturePythonRoot() else { return }
    try await withWorkFutureHost(root: root) { host, session in
        let calls = WorkFutureCallbackLog()
        let spawnCounter = WorkFutureSpawnCounter()
        let admittedDeadline = Date().addingTimeInterval(60).timeIntervalSince1970
        let uncertainDeadline = Date().addingTimeInterval(60).timeIntervalSince1970
        await host.onCallback { _, _, kind, payload in
            calls.record(kind)
            guard kind == "spawn" else {
                if kind == "agent_handle_status" {
                    let id = payload["id"]?.stringValue ?? ""
                    let deadline = id == "work-uncertain-id" ? uncertainDeadline : admittedDeadline
                    return workFutureRecord(id: id, deadline: deadline, state: "running", outcome: nil)
                }
                return .object(["error": .string("unexpected callback")])
            }
            let spawnCount = spawnCounter.next()
            let id = spawnCount == 1 ? "work-admitted-id" : "work-uncertain-id"
            let state = spawnCount == 1 ? "admitted" : "admission_uncertain"
            let deadline = spawnCount == 1 ? admittedDeadline : uncertainDeadline
            return .object([
                "id": .string(id), "name": .string("future-child"),
                "ownership": .string("work"), "state": .string(state),
                "deadline": .number(deadline),
            ])
        }

        let admitted = try await host.execute(
            "first = spawn('first', name='first')\n(first.aviary_id, first.aviary_ownership)",
            in: session, timeout: 5)
        let uncertain = try await host.execute(
            "second = spawn('second', name='second')\n(second.aviary_id, second.aviary_ownership)",
            in: session, timeout: 5)
        XCTAssertEqual(admitted.value, "('work-admitted-id', 'work')")
        XCTAssertEqual(uncertain.value, "('work-uncertain-id', 'work')")
        XCTAssertNil(admitted.exception)
        XCTAssertNil(uncertain.exception)
        XCTAssertEqual(calls.kinds.filter { $0 == "spawn" }.count, 2)
        XCTAssertFalse(calls.kinds.contains("children"))
    }
}

func test_runtimeHostWorkFutureUsesExactHandlePollingAndRetainsChunkedBody() async throws {
    guard let root = workFuturePythonRoot() else { return }
    try await withWorkFutureHost(root: root) { host, session in
        let body = Data(repeating: 0x41, count: 300_000)
        let digest = "sha256:" + AviarySHA256.hash(data: body).description
        let deadline = Date().addingTimeInterval(60).timeIntervalSince1970
        let log = WorkFutureCallbackLog()
        await host.onCallback { _, _, kind, payload in
            log.record(kind)
            switch kind {
            case "agent_handle_status":
                return workFutureRecord(id: "retained-handle", deadline: deadline)
            case "agent_handle_result":
                guard let offset = payload["offset"]?.intValue else {
                    return .object(["error": .string("missing offset")])
                }
                let end = min(body.count, offset + 256 * 1024)
                return .object([
                    "id": .string("retained-handle"),
                    "offset": .number(Double(offset)),
                    "next_offset": .number(Double(end)),
                    "byte_count": .number(Double(body.count)),
                    "body_digest": .string(digest),
                    "data_base64": .string(body.subdata(in: offset..<end).base64EncodedString()),
                    "eof": .bool(end == body.count),
                ])
            default:
                return .object(["error": .string("unexpected callback")])
            }
        }

        let result = try await host.execute(
            "one = attach_agent('retained-handle', name='bound')\n"
                + "first = one.result()\n"
                + "two = attach_agent('retained-handle')\n"
                + "second = two.result()\n"
                + "(len(first), first == second)",
            in: session, timeout: 10)
        XCTAssertEqual(result.value, "(300000, True)")
        XCTAssertNil(result.exception)
        XCTAssertFalse(log.kinds.contains("children"))
        XCTAssertEqual(log.kinds.filter { $0 == "agent_handle_status" }.count, 4)
        XCTAssertEqual(log.kinds.filter { $0 == "agent_handle_result" }.count, 4)

        let collision = try await host.execute(
            "x = 'keep'\n"
                + "try:\n"
                + "    attach_agent('retained-handle', name='x')\n"
                + "    collision = False\n"
                + "except ValueError:\n"
                + "    collision = True\n"
                + "(collision, x)",
            in: session, timeout: 5)
        XCTAssertEqual(collision.value, "(True, 'keep')")
        XCTAssertNil(collision.exception)
        XCTAssertEqual(log.kinds.filter { $0 == "agent_handle_status" }.count, 4)
    }
}

func test_runtimeHostWorkFutureMissingBodyAndTamperedDigestFailClosed() async throws {
    guard let root = workFuturePythonRoot() else { return }
    let missing = try await withWorkFutureHost(root: root) { host, session in
        let deadline = Date().addingTimeInterval(60).timeIntervalSince1970
        await host.onCallback { _, _, kind, _ in
            if kind == "agent_handle_status" {
                return workFutureRecord(id: "missing-body", deadline: deadline)
            }
            return .object(["error": .string("retained body is unavailable")])
        }
        return try await host.execute(
            "f = attach_agent('missing-body')\n"
                + "try:\n"
                + "    f.result(timeout=2)\n"
                + "    error = False\n"
                + "except RuntimeError as e:\n"
                + "    error = 'unavailable' in str(e)\n"
                + "error",
            in: session, timeout: 5)
    }
    XCTAssertEqual(missing.value, "True")
    XCTAssertNil(missing.exception)

    let tampered = try await withWorkFutureHost(root: root) { host, session in
        let deadline = Date().addingTimeInterval(60).timeIntervalSince1970
        await host.onCallback { _, _, kind, _ in
            if kind == "agent_handle_status" {
                return workFutureRecord(id: "tampered-body", deadline: deadline)
            }
            return .object([
                "id": .string("tampered-body"), "offset": .number(0),
                "next_offset": .number(1), "byte_count": .number(1),
                "body_digest": .string("sha256:" + String(repeating: "0", count: 64)),
                "data_base64": .string("YQ=="), "eof": .bool(true),
            ])
        }
        return try await host.execute(
            "f = attach_agent('tampered-body')\n"
                + "try:\n"
                + "    f.result(timeout=2)\n"
                + "    error = False\n"
                + "except RuntimeError as e:\n"
                + "    error = 'digest mismatch' in str(e)\n"
                + "error",
            in: session, timeout: 5)
    }
    XCTAssertEqual(tampered.value, "True")
    XCTAssertNil(tampered.exception)
}

func test_runtimeHostWorkFutureResultTimeoutIsLocalAndCancelIsNonDurable() async throws {
    guard let root = workFuturePythonRoot() else { return }
    try await withWorkFutureHost(root: root) { host, session in
        let log = WorkFutureCallbackLog()
        let deadline = Date().addingTimeInterval(60).timeIntervalSince1970
        await host.onCallback { _, _, kind, _ in
            log.record(kind)
            if kind == "agent_handle_status" {
                return workFutureRecord(
                    id: "running-handle", deadline: deadline, state: "running", outcome: nil)
            }
            return .object(["error": .string("unexpected callback")])
        }
        let result = try await host.execute(
            "f = attach_agent('running-handle')\n"
                + "cancelled = f.cancel()\n"
                + "try:\n"
                + "    f.result(timeout=0.05)\n"
                + "except TimeoutError:\n"
                + "    timed_out = True\n"
                + "(cancelled, timed_out)",
            in: session, timeout: 5)
        XCTAssertEqual(result.value, "(False, True)")
        XCTAssertNil(result.exception)
        XCTAssertFalse(log.kinds.contains("agent_handle_cancel"))
    }
}

func test_runtimeHostWorkFutureAwaitInterestIsObservableWhileBlocked() async throws {
    guard let root = workFuturePythonRoot() else { return }
    try await withWorkFutureHost(root: root) { host, session in
        let gate = WorkFutureInterestGate()
        let deadline = Date().addingTimeInterval(60).timeIntervalSince1970
        await host.onCallback { _, _, kind, _ in
            if kind == "agent_handle_status" {
                return workFutureRecord(
                    id: "interest-handle", deadline: deadline, state: "running", outcome: nil)
            }
            if kind == "agent_handle_await" { return await gate.serve() }
            return .object(["error": .string("unexpected callback")])
        }

        let execution = Task {
            try await host.execute(
                "f = attach_agent('interest-handle')\n"
                    + "try:\n"
                    + "    f.result(timeout=0.8)\n"
                    + "except TimeoutError:\n"
                    + "    timed_out = True\n"
                    + "timed_out",
                in: session, timeout: 5)
        }
        try await gate.waitUntilObserved()
        let result = try await execution.value
        XCTAssertEqual(result.value, "True")
        XCTAssertNil(result.exception)
        await gate.release()
    }
}

func test_runtimeHostWorkFutureCanSettleAfterPastDeadline() async throws {
    guard let root = workFuturePythonRoot() else { return }
    try await withWorkFutureHost(root: root) { host, session in
        let body = Data("settled-after-scope".utf8)
        let digest = "sha256:" + AviarySHA256.hash(data: body).description
        let deadline = Date().addingTimeInterval(-1).timeIntervalSince1970
        let statusCounter = WorkFutureSpawnCounter()
        await host.onCallback { _, _, kind, payload in
            switch kind {
            case "agent_handle_status":
                let status = statusCounter.next() < 3 ? "running" : "terminal"
                return workFutureRecord(
                    id: "past-deadline-handle", deadline: deadline,
                    state: status, outcome: status == "terminal" ? "succeeded" : nil)
            case "agent_handle_result":
                let offset = payload["offset"]?.intValue ?? 0
                return .object([
                    "id": .string("past-deadline-handle"),
                    "offset": .number(Double(offset)),
                    "next_offset": .number(Double(body.count)),
                    "byte_count": .number(Double(body.count)),
                    "body_digest": .string(digest),
                    "data_base64": .string(body.base64EncodedString()),
                    "eof": .bool(true),
                ])
            default:
                return .object(["error": .string("unexpected callback")])
            }
        }
        let result = try await host.execute(
            "f = attach_agent('past-deadline-handle')\n"
                + "f.result(timeout=3)",
            in: session, timeout: 5)
        XCTAssertEqual(result.value, "'settled-after-scope'")
        XCTAssertNil(result.exception)
    }
}

func test_runtimeHostWorkFutureWithoutDeadlineUsesCanonicalCompletion() async throws {
    guard let root = workFuturePythonRoot() else { return }
    try await withWorkFutureHost(root: root) { host, session in
        let body = Data("unlimited-child-finished".utf8)
        let counter = WorkFutureSpawnCounter()
        await host.onCallback { _, _, kind, _ in
            switch kind {
            case "agent_handle_status":
                let state = counter.next() < 3 ? "running" : "terminal"
                return workFutureRecord(
                    id: "no-deadline-child", deadline: nil, state: state,
                    outcome: state == "terminal" ? "succeeded" : nil)
            case "agent_handle_result":
                return .object([
                    "id": .string("no-deadline-child"), "offset": .number(0),
                    "next_offset": .number(Double(body.count)),
                    "byte_count": .number(Double(body.count)),
                    "body_digest": .string("sha256:" + AviarySHA256.hash(data: body).description),
                    "data_base64": .string(body.base64EncodedString()), "eof": .bool(true),
                ])
            case "agent_handle_await": return .object(["accepted": .bool(true)])
            default: return .object(["error": .string("unexpected callback")])
            }
        }
        let result = try await host.execute(
            "f = attach_agent('no-deadline-child')\n(f.aviary_deadline, f.result(timeout=3))",
            in: session, timeout: 5)
        XCTAssertNil(result.exception)
        XCTAssertEqual(result.value, "(None, 'unlimited-child-finished')")
        await host.onCallback { _, _, _, payload in
            let id = payload["id"]?.stringValue ?? "bad"
            var row: [String: JSONValue] = ["id": .string(id), "ownership": .string("work")]
            if id == "bad-bool" { row["deadline"] = .bool(false) }
            if id == "bad-string" { row["deadline"] = .string("unlimited") }
            return .object(row)
        }
        let malformed = try await host.execute("""
        rejected = []
        for handle in ['bad-missing', 'bad-bool', 'bad-string']:
            try:
                attach_agent(handle)
                rejected.append(False)
            except RuntimeError:
                rejected.append(True)
        rejected
        """, in: session, timeout: 5)
        XCTAssertNil(malformed.exception)
        XCTAssertEqual(malformed.value, "[True, True, True]")
    }
}

func test_runtimeHostWorkFutureAttachAgentIsHiddenFromNamespaceInspection() async throws {
    guard let root = workFuturePythonRoot() else { return }
    try await withWorkFutureHost(root: root) { host, session in
        let deadline = Date().addingTimeInterval(60).timeIntervalSince1970
        await host.onCallback { _, _, kind, _ in
            if kind == "agent_handle_status" {
                return workFutureRecord(
                    id: "hidden-attach-handle", deadline: deadline,
                    state: "running", outcome: nil)
            }
            return .object(["error": .string("unexpected callback")])
        }
        let execution = try await host.execute(
            "f = attach_agent('hidden-attach-handle')\nf.aviary_id",
            in: session, timeout: 5)
        XCTAssertEqual(execution.value, "'hidden-attach-handle'")
        XCTAssertNil(execution.exception)
        let namespace = try await host.inspect(session)
        XCTAssertFalse(namespace.bindings.contains { $0.name == "attach_agent" })
    }
}

let casesRuntimeHostWorkAgentFuture: [Case] = [
    ("runtimeHost work Future with no deadline waits for canonical completion", {
        try await test_runtimeHostWorkFutureWithoutDeadlineUsesCanonicalCompletion()
    }),
    ("runtimeHost work Future preserves admitted and uncertain IDs", {
        try await test_runtimeHostWorkFuturePreservesAdmittedAndUncertainIDs()
    }),
    ("runtimeHost work Future polls exact Handles and retains chunked bodies", {
        try await test_runtimeHostWorkFutureUsesExactHandlePollingAndRetainsChunkedBody()
    }),
    ("runtimeHost work Future rejects missing and tampered bodies", {
        try await test_runtimeHostWorkFutureMissingBodyAndTamperedDigestFailClosed()
    }),
    ("runtimeHost work Future timeout and cancel stay local", {
        try await test_runtimeHostWorkFutureResultTimeoutIsLocalAndCancelIsNonDurable()
    }),
    ("runtimeHost work Future reports await interest", {
        try await test_runtimeHostWorkFutureAwaitInterestIsObservableWhileBlocked()
    }),
    ("runtimeHost work Future settles after a past deadline", {
        try await test_runtimeHostWorkFutureCanSettleAfterPastDeadline()
    }),
    ("runtimeHost work Future attach_agent stays out of namespace inspection", {
        try await test_runtimeHostWorkFutureAttachAgentIsHiddenFromNamespaceInspection()
    }),
]
