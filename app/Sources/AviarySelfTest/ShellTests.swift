import Foundation
@testable import AviaryCore

private func shellIsAvailable() -> Bool {
    FileManager.default.isExecutableFile(atPath: "/bin/zsh")
}

func test_shellRunDetachesImplicitStdin() async throws {
    guard shellIsAvailable() else {
        print("      skipped: /bin/zsh missing")
        return
    }
    guard case .success(let result) = await Shell.run(
        "/bin/zsh",
        ["-lc", "if [ -t 0 ]; then printf tty; else printf detached; fi"],
        timeout: 5) else {
        XCTFail("detached shell failed to launch")
        return
    }
    XCTAssertTrue(result.ok)
    XCTAssertEqual(result.stdout, "detached")
}

func test_shellRunStillDeliversExplicitStdin() async throws {
    guard case .success(let result) = await Shell.run(
        "/bin/sh",
        ["-c", "IFS= read -r line; printf '%s' \"$line\""],
        stdin: "input-from-caller\n",
        timeout: 5) else {
        XCTFail("stdin shell failed to launch")
        return
    }
    XCTAssertTrue(result.ok)
    XCTAssertEqual(result.stdout, "input-from-caller")
}

func test_shellRunTimeoutIsFailure() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else {
        print("      skipped: /bin/sh missing")
        return
    }
    let started = Date()
    let result = await Shell.run(
        "/bin/sh",
        ["-c", "trap '' TERM; while :; do :; done"],
        timeout: 0.15)
    guard case .failure(.timedOut(let command, let after)) = result else {
        XCTFail("a deadline-killed process must report ShellError.timedOut")
        return
    }
    XCTAssertEqual(command, "/bin/sh")
    XCTAssertEqual(after, 0.15)
    // TERM is given a bounded grace period before KILL. This also protects the UI from a
    // child that ignores TERM, while allowing enough room for a busy CI host.
    XCTAssertTrue(Date().timeIntervalSince(started) < 5.0)
}

func test_shellRunCancellationIsFailure() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else {
        print("      skipped: /bin/sh missing")
        return
    }
    let task = Task {
        await Shell.run(
            "/bin/sh",
            ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 30)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    let result = await task.value
    guard case .failure(.cancelled(let command)) = result else {
        XCTFail("a cancelled process must report ShellError.cancelled")
        return
    }
    XCTAssertEqual(command, "/bin/sh")
}

func test_shellRunSignaledProcessRemainsProcessResult() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else {
        print("      skipped: /bin/sh missing")
        return
    }
    guard case .success(let result) = await Shell.run(
        "/bin/sh", ["-c", "kill -TERM $$"], timeout: 5) else {
        XCTFail("a normally launched signaled process should remain a ProcessResult")
        return
    }
    XCTAssertFalse(result.ok)
    XCTAssertNotEqual(result.exitCode, 0)
}

func test_loginShellExecutesWithoutInteractiveJobControl() async throws {
    guard shellIsAvailable() else {
        print("      skipped: /bin/zsh missing")
        return
    }
    guard case .success(let result) = await Shell.loginShell("printf login-shell-ok", timeout: 5) else {
        XCTFail("login shell failed to launch")
        return
    }
    XCTAssertTrue(result.ok)
    XCTAssertEqual(result.stdout, "login-shell-ok")
}

func test_processEnvironmentCoalescesConcurrentLoads() async throws {
    guard shellIsAvailable() else {
        print("      skipped: /bin/zsh missing")
        return
    }
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<8 {
            group.addTask { await ProcessEnvironment.shared.loadFromLoginShell() }
        }
        var values: [Bool] = []
        for await value in group { values.append(value) }
        return values
    }
    XCTAssertEqual(results.count, 8)
    XCTAssertTrue(results.allSatisfy { $0 })
    XCTAssertTrue(ProcessEnvironment.shared.isLoginShellEnvironment)
}

let casesShell: [Case] = [
    ("Shell: no implicit stdin inherits the controlling terminal", {
        try await test_shellRunDetachesImplicitStdin()
    }),
    ("Shell: explicit stdin remains connected", {
        try await test_shellRunStillDeliversExplicitStdin()
    }),
    ("Shell: timeout is a truthful failure", {
        try await test_shellRunTimeoutIsFailure()
    }),
    ("Shell: cancellation is a truthful failure", {
        try await test_shellRunCancellationIsFailure()
    }),
    ("Shell: signaled children retain ProcessResult semantics", {
        try await test_shellRunSignaledProcessRemainsProcessResult()
    }),
    ("Shell: login commands execute without interactive job control", {
        try await test_loginShellExecutesWithoutInteractiveJobControl()
    }),
    ("Shell: concurrent login environment loads coalesce", {
        try await test_processEnvironmentCoalescesConcurrentLoads()
    }),
]
