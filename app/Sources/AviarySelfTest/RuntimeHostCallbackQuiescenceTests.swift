import Foundation
import Darwin
@testable import AviaryCore

/// A small async latch keeps callback tests deterministic without sleeping in the callback
/// itself. The callback must be allowed to suspend: that is the race which used to let journal
/// close win over an in-flight callback effect.
private final class CallbackLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if register(continuation) { continuation.resume() }
        }
    }

    /// Returns true when the latch was already open. Kept synchronous so Swift's async-safety
    /// checker does not mistake the deliberately short lock hold for a blocking async operation.
    private func register(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if opened { return true }
        waiters.append(continuation)
        return false
    }

    func open() {
        lock.lock()
        guard !opened else {
            lock.unlock()
            return
        }
        opened = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened
    }
}

private enum CallbackTestError: Error, Equatable {
    case handlerFailed
}

private final class CallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock(); value += 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private func launchCallbackFloodHost(
    endpoint: RuntimeHost.SocketEndpoint,
    identity: RuntimeHost.HostIdentity,
    callbackCount: Int
) throws -> Process {
    let source = #"""
import json, os, socket, sys, time
path, host_id, instance_id, callback_count = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
os.chmod(path, 0o600)
server.listen(1)
connection, _ = server.accept()
reader = connection.makefile("rb")
connection.sendall((json.dumps({
    "event": "ready", "protocol": 3, "runtime": "callback-flood",
    "runtimeVersion": "test", "hostID": host_id, "instanceID": instance_id,
    "transport": "unix", "features": {"callbacks": True},
}) + "\n").encode())
for index in range(int(callback_count)):
    connection.sendall((json.dumps({
        "event": "callback", "rid": "flood-" + str(index), "kind": "flood",
        "payload": {"index": index}, "session": "flood-session",
    }) + "\n").encode())
refusals = 0
while refusals < max(0, int(callback_count) - 32):
    message = json.loads(reader.readline())
    if message.get("op") != "callback.result":
        continue
    refusals += 1
    connection.sendall((json.dumps({
        "id": message.get("id"), "ok": True,
        "data": {"delivered": True, "status": "accepted"},
    }) + "\n").encode())
connection.sendall((json.dumps({
    "event": "output", "session": "flood-session", "stream": "stdout",
    "text": "refusals-complete",
}) + "\n").encode())
time.sleep(5)
"""#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", "-c", source, endpoint.path, identity.hostID, identity.instanceID,
        String(callbackCount),
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func test_runtimeHostDrainsSlowCallbacksBeforeQuiescence() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let session = try await host.createSession()
    let started = CallbackLatch()
    let release = CallbackLatch()
    let finished = CallbackLatch()
    await host.onCallback { _, _, _, _ in
        started.open()
        await release.wait()
        finished.open()
        return .object(["answer": .string("done")])
    }

    let execution = Task { try await host.execute("ask_app('slow')", in: session) }
    await started.wait()
    XCTAssertEqual(await host.activeCallbackCount, 1)

    let drain = Task { try await host.closeCallbackAdmissionAndWait() }
    try await Task.sleep(nanoseconds: 50_000_000)
    // Closing admission does not cancel an admitted effect; the owner must wait for it.
    XCTAssertFalse(finished.isOpen, "drain returned before callback completed")
    release.open()
    try await drain.value
    await finished.wait()
    XCTAssertEqual(await host.activeCallbackCount, 0)
    XCTAssertFalse(await host.isCallbackAdmissionOpen)
    _ = try await execution.value
    await host.stop()
}

func test_runtimeHostPropagatesCallbackHandlerFailureThroughDrain() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let session = try await host.createSession()
    await host.onCallback { _, _, _, _ in throw CallbackTestError.handlerFailed }

    _ = try await host.execute("ask_app('failure')", in: session)
    do {
        try await host.closeCallbackAdmissionAndWait()
        XCTFail("callback handler failure was swallowed")
    } catch let error as CallbackTestError {
        XCTAssertEqual(error, .handlerFailed)
    } catch {
        XCTFail("expected handler error, got \(error)")
    }
    await host.stop()
}

func test_runtimeHostBoundsAdmittedCallbackTasksDuringFlood() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-callback-flood-\(String(UUID().uuidString.prefix(8)))",
                   directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = RuntimeHost.SocketEndpoint(path: root.appending(path: "host.sock").path)
    let identity = RuntimeHost.HostIdentity(hostID: "callback-flood", instanceID: "instance")
    let process = try launchCallbackFloodHost(
        endpoint: endpoint, identity: identity, callbackCount: 128)
    defer {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    let host = RuntimeHost(endpoint: endpoint, expectedIdentity: identity)
    let release = CallbackLatch()
    let refusalsComplete = CallbackLatch()
    let count = CallbackCount()
    await host.onOutput { _, _, text in
        if text == "refusals-complete" { refusalsComplete.open() }
    }
    await host.onCallback { _, _, _, _ in
        count.increment()
        await release.wait()
        return .object(["answer": .string("released")])
    }
    _ = try await host.connect(timeout: 2)
    let admissionDeadline = Date().addingTimeInterval(2)
    while Date() < admissionDeadline {
        let activeCallbacks = await host.activeCallbackCount
        if refusalsComplete.isOpen, activeCallbacks == 32 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    // A callback event is not free: it owns an application task until its response is delivered.
    // The host must refuse excess work instead of tracking all 128 callbacks indefinitely.
    XCTAssertTrue(count.count > 0, "the flood fixture never delivered its first callback")
    XCTAssertEqual(await host.activeCallbackCount, 32)
    XCTAssertEqual(count.count, 32)
    XCTAssertTrue(
        refusalsComplete.isOpen,
        "not every callback over the handler limit received a bounded refusal")
    await host.stop(callbackDrainTimeout: 0.1)
    // Let the unstructured callback tasks settle after transport teardown; they were deliberately
    // left tracked while stop enforced its deadline.
    release.open()
    // The self-test executable intentionally waits for child Tasks at process exit. Releasing the
    // handlers without joining them makes this otherwise-correct test appear to hang after its
    // assertions, and would also hide a callback that failed to leave the tracked set.
    try? await host.closeCallbackAdmissionAndWait()
    XCTAssertEqual(await host.activeCallbackCount, 0)
}

func test_runtimeHostStopRemainsBoundedForAStuckCallback() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let session = try await host.createSession(id: "stuck-callback")
    let started = CallbackLatch()
    let release = CallbackLatch()
    await host.onCallback { _, _, _, _ in
        started.open()
        await release.wait()
        return .object(["answer": .string("eventually" )])
    }

    let execution = Task {
        try await host.execute("ask_app('stuck')", in: session, timeout: 3)
    }
    await started.wait()
    let stopStarted = Date()
    await host.stop(callbackDrainTimeout: 0.1)
    let elapsed = Date().timeIntervalSince(stopStarted)

    XCTAssertTrue(elapsed < 2, "a stuck callback prevented owned process teardown")
    XCTAssertFalse(await host.isConnected)
    XCTAssertFalse(await host.isRunning)
    XCTAssertFalse(await host.hostProcessIsRunning)
    // The handler was admitted and is still waiting. Stop must report that truth rather than
    // deleting/canceling an application task it could not actually finish.
    XCTAssertEqual(await host.activeCallbackCount, 1)

    // Release the test's deliberately stuck application callback so the unstructured task does
    // not outlive the self-test process. Its response cannot be delivered after stop, which is a
    // truthful transport failure for the original execution.
    release.open()
    _ = try? await execution.value
}

func test_runtimeHostDoesNotAdmitCallbacksAfterAdmissionCloses() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let first = try await host.createSession()
    let second = try await host.createSession()
    let started = CallbackLatch()
    let release = CallbackLatch()
    let count = CallbackCount()
    await host.onCallback { _, _, _, _ in
        count.increment()
        started.open()
        await release.wait()
        return .object(["answer": .string("first")])
    }

    let firstExecution = Task { try await host.execute("ask_app('first')", in: first) }
    await started.wait()
    // Close admission synchronously on the actor before starting the drain task, so the second
    // request cannot win a scheduling race with the lifecycle boundary.
    await host.closeCallbackAdmission()
    let drain = Task { try await host.waitUntilCallbacksQuiescent() }
    // The second runtime session can emit a callback while the first one is still draining.
    // It must not enter the handler after the admission boundary.
    let secondExecution = Task {
        try await host.execute("ask_app('second')", in: second, timeout: 1)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(count.count, 1, "a post-close callback reached the handler")
    release.open()
    try await drain.value
    _ = try? await firstExecution.value
    let secondResult = try await secondExecution.value
    XCTAssertTrue(
        secondResult.value?.contains("admission closed") == true,
        "post-close callback should receive an explicit refusal")
    await host.stop()
}

func test_runtimeHostCallHookPropagatesTransportFailure() async throws {
    let host = RuntimeHost(executable: "/does/not/exist", arguments: [])
    do {
        _ = try await host.callHook("before_tool", payload: .object([:]))
        XCTFail("callHook converted a transport failure into nil")
    } catch let error as RuntimeHost.HostError {
        XCTAssertEqual(error.errorDescription, RuntimeHost.HostError.notRunning.errorDescription)
    } catch {
        XCTFail("expected RuntimeHost.HostError.notRunning, got \(error)")
    }
}

let casesRuntimeHostCallbackQuiescence: [Case] = [
    ("runtimeHost: slow callbacks drain before quiescence", {
        try await test_runtimeHostDrainsSlowCallbacksBeforeQuiescence()
    }),
    ("runtimeHost: callback handler failures reach the drain API", {
        try await test_runtimeHostPropagatesCallbackHandlerFailureThroughDrain()
    }),
    ("runtimeHost: callback floods remain bounded", {
        try await test_runtimeHostBoundsAdmittedCallbackTasksDuringFlood()
    }),
    ("runtimeHost: stop tears down despite a stuck callback", {
        try await test_runtimeHostStopRemainsBoundedForAStuckCallback()
    }),
    ("runtimeHost: callbacks after admission close never reach the handler", {
        try await test_runtimeHostDoesNotAdmitCallbacksAfterAdmissionCloses()
    }),
    ("runtimeHost: hook transport failures are not converted to nil", {
        try await test_runtimeHostCallHookPropagatesTransportFailure()
    }),
]
