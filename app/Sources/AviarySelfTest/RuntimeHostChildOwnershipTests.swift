import Foundation

@testable import AviaryCore

private final class ChildOwnershipGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func signal() {
        lock.lock()
        open = true
        lock.unlock()
    }

    func wait() async {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private func waitForChildOwnershipCondition(
    timeout: TimeInterval = 2,
    _ condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

func test_runtimeHostChildOwnershipRequiresFreshLeasedLauncher() async throws {
    guard let leased = try makeHost(.reference),
          let root = EngineLocator.repoRoot(),
          let unleased = RuntimeHost.bundledPython(
            repoRoot: root, variant: HostVariant.reference.rawValue,
            parentLifetimeLease: false)
    else { return }

    XCTAssertTrue(await leased.claimChildExecutionOwnership())
    XCTAssertFalse(
        await leased.claimChildExecutionOwnership(),
        "one runtime launcher cannot be claimed by two child executions")
    let neverStarted = await leased.stopWithReceipt()
    XCTAssertTrue(neverStarted.ownedProcessExitVerified)
    XCTAssertTrue(neverStarted.callbacksQuiescent)

    XCTAssertFalse(
        await unleased.claimChildExecutionOwnership(),
        "a child runtime must be leased to its Work Host process")
    let unleasedReceipt = await unleased.stopWithReceipt()
    XCTAssertTrue(unleasedReceipt.ownedProcessExitVerified)

    let adopted = RuntimeHost(
        endpoint: .init(path: "/tmp/aviary-child-ownership-missing.sock"),
        expectedIdentity: .init(hostID: "adopted-host", instanceID: "adopted-instance"))
    XCTAssertFalse(
        await adopted.claimChildExecutionOwnership(),
        "an adopted runtime is not a fresh child-owned process")
    let adoptedReceipt = await adopted.stopWithReceipt(callbackDrainTimeout: 0.01)
    XCTAssertFalse(adoptedReceipt.ownedProcessExitVerified)
    XCTAssertTrue(adoptedReceipt.callbacksQuiescent)

    guard let running = try makeHost(.reference) else { return }
    _ = try await running.start()
    XCTAssertFalse(
        await running.claimChildExecutionOwnership(),
        "an already-started runtime cannot become a child-owned process")
    let runningReceipt = await running.stopWithReceipt()
    XCTAssertTrue(runningReceipt.ownedProcessExitVerified)
    XCTAssertTrue(runningReceipt.callbacksQuiescent)
}

func test_runtimeHostChildOwnershipCleanStopVerifiesRealProcessExit() async throws {
    guard let host = try makeHost(.reference) else { return }
    XCTAssertTrue(await host.claimChildExecutionOwnership())
    _ = try await host.start()

    let receipt = await host.stopWithReceipt()
    XCTAssertTrue(receipt.ownedProcessExitVerified)
    XCTAssertTrue(receipt.callbacksQuiescent)
    XCTAssertFalse(await host.hostProcessIsRunning)
    XCTAssertFalse(await host.isRunning)
}

func test_runtimeHostChildOwnershipStopReportsStuckCallback() async throws {
    guard let host = try makeHost(.reference) else { return }
    XCTAssertTrue(await host.claimChildExecutionOwnership())
    _ = try await host.start()
    let session = try await host.createSession(id: "child-ownership-stuck-callback")
    let callbackStarted = ChildOwnershipGate()
    let releaseCallback = ChildOwnershipGate()
    await host.onCallback { _, _, _, _ in
        callbackStarted.signal()
        await releaseCallback.wait()
        return .object(["answer": .string("released")])
    }

    let execution = Task {
        try await host.execute("ask_app('stuck')", in: session, timeout: 5)
    }
    guard await waitForChildOwnershipCondition({ callbackStarted.isOpen }) else {
        releaseCallback.signal()
        await host.stop()
        _ = try? await execution.value
        XCTFail("runtime callback did not reach the admitted handler")
        return
    }

    let receipt = await host.stopWithReceipt(callbackDrainTimeout: 0.05)
    XCTAssertTrue(receipt.ownedProcessExitVerified)
    XCTAssertFalse(
        receipt.callbacksQuiescent,
        "a stopped process must not erase a still-admitted application callback")
    XCTAssertEqual(await host.activeCallbackCount, 1)

    releaseCallback.signal()
    _ = try? await execution.value
    XCTAssertTrue(await waitForChildOwnershipCondition {
        await host.activeCallbackCount == 0
    }, "released callback did not leave the tracked set")
}

func test_runtimeHostChildOwnershipRejectsStartDuringStopThenRestarts() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let session = try await host.createSession(id: "child-ownership-stop-start")
    let callbackStarted = ChildOwnershipGate()
    let releaseCallback = ChildOwnershipGate()
    await host.onCallback { _, _, _, _ in
        callbackStarted.signal()
        await releaseCallback.wait()
        return .object(["answer": .string("released")])
    }

    let execution = Task {
        try await host.execute("ask_app('overlap')", in: session, timeout: 5)
    }
    guard await waitForChildOwnershipCondition({ callbackStarted.isOpen }) else {
        releaseCallback.signal()
        await host.stop()
        _ = try? await execution.value
        XCTFail("runtime callback did not reach the admitted handler")
        return
    }

    let stop = Task { await host.stopWithReceipt(callbackDrainTimeout: 1) }
    guard await waitForChildOwnershipCondition({ !(await host.isCallbackAdmissionOpen) }) else {
        releaseCallback.signal()
        _ = await stop.value
        _ = try? await execution.value
        XCTFail("runtime stop did not close callback admission")
        return
    }

    do {
        _ = try await host.start()
        XCTFail("runtime restarted while its prior process was still stopping")
    } catch let error as RuntimeHost.HostError {
        XCTAssertTrue(
            error.localizedDescription.contains("still stopping"),
            "overlapping start returned the wrong bounded refusal: \(error.localizedDescription)")
    } catch {
        XCTFail("overlapping start returned an unexpected error: \(error)")
    }

    releaseCallback.signal()
    let firstStop = await stop.value
    XCTAssertTrue(firstStop.ownedProcessExitVerified)
    XCTAssertTrue(firstStop.callbacksQuiescent)
    _ = try? await execution.value

    let restarted = try await host.start()
    XCTAssertNotNil(restarted.identity)
    XCTAssertTrue(await host.isRunning)
    let finalStop = await host.stopWithReceipt()
    XCTAssertTrue(finalStop.ownedProcessExitVerified)
    XCTAssertTrue(finalStop.callbacksQuiescent)
}

let casesRuntimeHostChildOwnership: [Case] = [
    ("phase5 child runtime: ownership requires one fresh leased launcher", {
        try await test_runtimeHostChildOwnershipRequiresFreshLeasedLauncher()
    }),
    ("phase5 child runtime: clean stop verifies the owned process exit", {
        try await test_runtimeHostChildOwnershipCleanStopVerifiesRealProcessExit()
    }),
    ("phase5 child runtime: stop receipt retains a stuck callback", {
        try await test_runtimeHostChildOwnershipStopReportsStuckCallback()
    }),
    ("phase5 child runtime: stop rejects overlap and permits later restart", {
        try await test_runtimeHostChildOwnershipRejectsStartDuringStopThenRestarts()
    }),
]
