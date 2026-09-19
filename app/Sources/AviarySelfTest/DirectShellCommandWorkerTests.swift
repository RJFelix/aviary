import Foundation
@testable import AviaryCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Focused process-semantics tests for the host-owned direct shell worker.  These use only
/// throwaway temporary directories and the small executable self-test assertions.
let casesDirectShellCommandWorker: [Case] = [
    ("Direct shell worker: shell normalization and exact cwd/environment", {
        let root = try directShellWorkerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = DirectShellCommandRequest(
            commandID: "command-cwd", actionID: "action-cwd", language: .sh,
            source: Data("printf '%s|%s' \"$DIRECT_WORKER_VALUE\" \"$(pwd -P)\"".utf8),
            workingDirectory: root,
            environment: ["DIRECT_WORKER_VALUE": "bytes-✓", "PATH": "/usr/bin:/bin"])
        let result = await DirectShellCommandWorker(request: request).wait()
        XCTAssertEqual(result.source, request.source)
        let physicalRoot = directShellWorkerRealPath(root)
        XCTAssertEqual(result.stdout.head, Data("bytes-✓|\(physicalRoot)".utf8))
        XCTAssertEqual(result.stdout.totalByteCount, Int64(result.stdout.head.count))
        do {
            let decoded = try JSONDecoder().decode(
                DirectShellCommandResult.self,
                from: JSONEncoder().encode(result))
            try decoded.validate()
        } catch {
            XCTAssertTrue(false, "a bounded result must round-trip and validate: \(error)")
        }
        if case .exited(let code) = result.status {
            XCTAssertEqual(code, 0)
        } else {
            XCTAssertTrue(false, "expected a clean shell exit, got \(result.status)")
        }
        XCTAssertEqual(DirectShellLanguage(wireValue: "shell"), .sh)
        XCTAssertEqual(DirectShellLanguage(wireValue: " BASH "), .bash)
    }),
    ("Direct shell worker: binary bytes and deterministic bounded captures", {
        let root = try directShellWorkerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "printf '\\001\\002\\377'; i=0; while [ $i -lt 70000 ]; do printf x; printf y >&2; i=$((i+1)); done"
        let result = await DirectShellCommandWorker(request: .init(
            commandID: "command-flood", actionID: "action-flood", language: .bash,
            source: source, workingDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"])).wait()

        XCTAssertEqual(result.stdout.totalByteCount, 70_003)
        XCTAssertEqual(result.stderr.totalByteCount, 70_000)
        XCTAssertEqual(Data(result.stdout.head.prefix(3)), Data([1, 2, 255]))
        XCTAssertEqual(result.stdout.head.count, 32 * 1024)
        XCTAssertEqual(result.stdout.tail, Data(repeating: UInt8(ascii: "x"), count: 32 * 1024))
        XCTAssertEqual(result.stderr.head, Data(repeating: UInt8(ascii: "y"), count: 32 * 1024))
        XCTAssertEqual(result.stderr.tail, Data(repeating: UInt8(ascii: "y"), count: 32 * 1024))
        XCTAssertEqual(result.stdout.omittedByteCount, 70_003 - 64 * 1024)
        XCTAssertEqual(result.stderr.omittedByteCount, 70_000 - 64 * 1024)
        XCTAssertTrue(result.stdout.isTruncated)
        XCTAssertTrue(result.stderr.isTruncated)
    }),
    ("Direct shell worker: no implicit timeout", {
        let root = try directShellWorkerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        let result = await DirectShellCommandWorker(request: .init(
            commandID: "command-no-timeout", actionID: "action-no-timeout", language: .sh,
            source: "sleep 0.2; printf finished", workingDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"])).wait()
        XCTAssertTrue(Date().timeIntervalSince(started) >= 0.15)
        XCTAssertEqual(result.stdout.head, Data("finished".utf8))
        if case .exited(let code) = result.status { XCTAssertEqual(code, 0) }
        else { XCTAssertTrue(false, "a command without a deadline must run to exit") }
    }),
    ("Direct shell worker: timeout and launch failure are distinct", {
        let root = try directShellWorkerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timedOut = await DirectShellCommandWorker(request: .init(
            commandID: "command-timeout", actionID: "action-timeout", language: .zsh,
            source: "sleep 5", workingDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"], timeout: 0.1)).wait()
        XCTAssertEqual(timedOut.status, .timedOut)

        let failed = await DirectShellCommandWorker(request: .init(
            commandID: "command-launch-failure", actionID: "action-launch-failure", language: .sh,
            source: "printf never", workingDirectory: root.appendingPathComponent("missing"),
            environment: ["PATH": "/usr/bin:/bin"])).wait()
        if case .launchFailed = failed.status { XCTAssertTrue(true) }
        else { XCTAssertTrue(false, "missing cwd must report launch failure") }
    }),
    ("Direct shell worker: invalid requests are rejected before spawn", {
        let root = try directShellWorkerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidIdentity = await DirectShellCommandWorker(request: .init(
            commandID: "bad\nidentity", actionID: "action-invalid", language: .sh,
            source: "touch should-not-exist", workingDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"])).wait()
        if case .invalidRequest = invalidIdentity.status { XCTAssertTrue(true) }
        else { XCTAssertTrue(false, "invalid identity must not reach spawn") }

        let invalidEnvironment = await DirectShellCommandWorker(request: .init(
            commandID: "command-invalid-env", actionID: "action-invalid-env", language: .sh,
            source: "printf never", workingDirectory: root,
            environment: ["BAD=KEY": "value"])).wait()
        if case .invalidRequest = invalidEnvironment.status { XCTAssertTrue(true) }
        else { XCTAssertTrue(false, "invalid environment must not be silently filtered") }
    }),
    ("Direct shell worker: escaped pipe descendants have bounded settlement", {
        let root = try directShellWorkerTemporaryDirectory()
        defer {
            if let pid = try? String(contentsOf: root.appendingPathComponent("escaped.pid"), encoding: .utf8),
               let value = Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) {
                _ = kill(value, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let started = Date()
        let result = await DirectShellCommandWorker(request: .init(
            commandID: "command-escaped-pipe", actionID: "action-escaped-pipe", language: .sh,
            source: "/usr/bin/python3 -c 'import os,time; os.setsid(); open(\"escaped.pid\",\"w\").write(str(os.getpid())); time.sleep(10)' & exit 0",
            workingDirectory: root, environment: ["PATH": "/usr/bin:/bin"])).wait()
        XCTAssertTrue(Date().timeIntervalSince(started) < 6, "pipe settlement must be bounded")
        XCTAssertTrue(!result.outputComplete, "abandoned inherited pipes must be reported incomplete")
        if case .exited(let code) = result.status { XCTAssertEqual(code, 0) }
        else { XCTAssertTrue(false, "root shell should have exited cleanly") }
    }),
    ("Direct shell worker: stop kills the process group and cancellation is safe", {
        let root = try directShellWorkerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = DirectShellCommandWorker(request: .init(
            commandID: "command-stop", actionID: "action-stop", language: .sh,
            source: "sleep 30 & echo $! > child.pid; wait", workingDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"]))
        await worker.start()
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("child.pid").path) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await worker.stop()
        let stopped = await worker.wait()
        XCTAssertEqual(stopped.status, .canceled)
        try? await Task.sleep(nanoseconds: 100_000_000)
        if case .success(let probe) = await Shell.run(
            "/bin/sh", ["-c", "kill -0 `cat child.pid`"], cwd: root, timeout: 1) {
            XCTAssertTrue(probe.exitCode != 0, "the stopped descendant must not remain alive")
        }
        await worker.stop()

        let cancelWorker = DirectShellCommandWorker(request: .init(
            commandID: "command-cancel", actionID: "action-cancel", language: .sh,
            source: "sleep 0.3; printf still-running > waiter-alive", workingDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"]))
        let waiter = Task { await cancelWorker.wait() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("waiter-alive").path),
                      "canceling a waiter must not stop the host-owned command")
        let canceled = await waiter.value
        XCTAssertEqual(canceled.status, .exited(exitCode: 0))
    }),
    ("Direct shell worker: stop before the launch critical section does not spawn", {
        let root = try directShellWorkerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DirectShellWorkerSpawnGate()
        let worker = DirectShellCommandWorker(
            request: .init(
                commandID: "command-prelaunch-stop", actionID: "action-prelaunch-stop",
                language: .sh, source: "touch must-not-start", workingDirectory: root,
                environment: ["PATH": "/usr/bin:/bin"]),
            preSpawnHook: { await gate.arriveAndWait() })
        await worker.start()
        var reached = false
        for _ in 0..<100 {
            if await gate.hasArrived {
                reached = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(reached, "the worker must reach the deterministic pre-spawn seam")
        await worker.stop()
        await gate.release()
        let result = await worker.wait()
        XCTAssertEqual(result.status, .canceled)
        XCTAssertFalse(await worker.hasLaunchedProcess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-start").path))
    })
]

private actor DirectShellWorkerSpawnGate {
    private(set) var hasArrived = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        hasArrived = true
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
        }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private func directShellWorkerTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-direct-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func directShellWorkerRealPath(_ url: URL) -> String {
    url.path.withCString { pointer in
        guard let resolved = realpath(pointer, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
