import Foundation
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

func test_runtimeHostDrainsSlowCallbacksBeforeQuiescence() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let session = try await host.createSession()
    let started = CallbackLatch()
    let release = CallbackLatch()
    let finished = CallbackLatch()
    await host.onCallback { _, _, _ in
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
    await host.onCallback { _, _, _ in throw CallbackTestError.handlerFailed }

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

func test_runtimeHostDoesNotAdmitCallbacksAfterAdmissionCloses() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let first = try await host.createSession()
    let second = try await host.createSession()
    let started = CallbackLatch()
    let release = CallbackLatch()
    let count = CallbackCount()
    await host.onCallback { _, _, _ in
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
    ("runtimeHost: callbacks after admission close never reach the handler", {
        try await test_runtimeHostDoesNotAdmitCallbacksAfterAdmissionCloses()
    }),
    ("runtimeHost: hook transport failures are not converted to nil", {
        try await test_runtimeHostCallHookPropagatesTransportFailure()
    }),
]
