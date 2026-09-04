import Darwin
import Foundation
@testable import AviaryCore

private func localDaemonLauncherScratch(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-daemon-launcher-" + name + "-" + UUID().uuidString.lowercased(),
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    guard chmod(root.path, mode_t(0o700)) == 0 else {
        throw NSError(domain: "AviarySelfTest", code: 1)
    }
    return root
}

private func localDaemonLauncherWrite(
    _ url: URL,
    _ contents: String,
    mode: mode_t = mode_t(0o600)
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    guard FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8),
                                        attributes: [.posixPermissions: NSNumber(value: Int16(mode))]) else {
        throw NSError(domain: "AviarySelfTest", code: 2)
    }
    guard chmod(url.path, mode) == 0 else {
        throw NSError(domain: "AviarySelfTest", code: 3)
    }
}

private func localDaemonLauncherShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func localDaemonLauncherWaitForFile(
    _ url: URL,
    timeout: TimeInterval = 3
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

private func localDaemonLauncherReadLines(_ url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    guard let value = String(data: data, encoding: .utf8) else { return [] }
    return value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func localDaemonLauncherExecutable(
    _ root: URL,
    body: String = "#!/bin/sh\nexit 0\n",
    mode: mode_t = mode_t(0o755)
) throws -> URL {
    let executable = root.appending(
        path: ".build/debug/aviaryd", directoryHint: .notDirectory)
    try localDaemonLauncherWrite(executable, body, mode: mode)
    return executable
}

private func localDaemonLauncherSource(_ root: URL) -> URL {
    root.appending(path: ".build/debug/Aviary", directoryHint: .notDirectory)
}

func testLocalAviaryDaemonLauncherResolutionUsesApprovedPrecedence() throws {
    let root = try localDaemonLauncherScratch("resolution")
    defer { try? FileManager.default.removeItem(at: root) }

    let bundleSource = root.appending(
        path: "Aviary.app/Contents/MacOS/Aviary", directoryHint: .notDirectory)
    let bundleHelper = root.appending(
        path: "Aviary.app/Contents/Helpers/aviaryd", directoryHint: .notDirectory)
    let buildSibling = try localDaemonLauncherExecutable(root)
    try localDaemonLauncherWrite(bundleHelper, "#!/bin/sh\nexit 0\n", mode: mode_t(0o755))

    let launcher = try LocalAviaryDaemonLauncher(
        agentHome: AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory)),
        sourceExecutableURL: bundleSource)
    let resolved = try launcher.resolveExecutable()
    XCTAssertEqual(resolved.origin, .appBundleHelper)
    XCTAssertEqual(resolved.url, bundleHelper.standardizedFileURL)

    let developmentLauncher = try LocalAviaryDaemonLauncher(
        agentHome: AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory)),
        sourceExecutableURL: localDaemonLauncherSource(root))
    let development = try developmentLauncher.resolveExecutable()
    XCTAssertEqual(development.origin, .swiftPMBuildSibling)
    XCTAssertEqual(development.url, buildSibling.standardizedFileURL)
}

func testLocalAviaryDaemonLauncherRejectsUnsafeCandidates() throws {
    let root = try localDaemonLauncherScratch("unsafe")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    let source = localDaemonLauncherSource(root)

    do {
        _ = try LocalAviaryDaemonLauncher(agentHome: home, sourceExecutableURL: source)
            .resolveExecutable()
        XCTFail("a missing sibling executable must be rejected")
    } catch let error as LocalAviaryDaemonLauncherError {
        XCTAssertEqual(error, .executableNotFound)
    } catch {
        XCTFail("unexpected missing-executable error")
    }

    let nonExecutable = try localDaemonLauncherExecutable(root, mode: mode_t(0o600))
    XCTAssertEqual(nonExecutable.lastPathComponent, "aviaryd")
    do {
        _ = try LocalAviaryDaemonLauncher(agentHome: home, sourceExecutableURL: source)
            .resolveExecutable()
        XCTFail("a non-executable regular file must be rejected")
    } catch let error as LocalAviaryDaemonLauncherError {
        XCTAssertEqual(error, .executableNotExecutable)
    } catch {
        XCTFail("unexpected non-executable error")
    }

    try? FileManager.default.removeItem(at: nonExecutable)
    let target = root.appending(path: "real-aviaryd", directoryHint: .notDirectory)
    try localDaemonLauncherWrite(target, "#!/bin/sh\nexit 0\n", mode: mode_t(0o755))
    try FileManager.default.createSymbolicLink(
        at: nonExecutable, withDestinationURL: target)
    do {
        _ = try LocalAviaryDaemonLauncher(agentHome: home, sourceExecutableURL: source)
            .resolveExecutable()
        XCTFail("a symlink executable must be rejected")
    } catch let error as LocalAviaryDaemonLauncherError {
        XCTAssertEqual(error, .executableSymlink)
    } catch {
        XCTFail("unexpected symlink error")
    }

    try? FileManager.default.removeItem(at: nonExecutable)
    try FileManager.default.createDirectory(at: nonExecutable, withIntermediateDirectories: true)
    do {
        _ = try LocalAviaryDaemonLauncher(agentHome: home, sourceExecutableURL: source)
            .resolveExecutable()
        XCTFail("a directory executable must be rejected")
    } catch let error as LocalAviaryDaemonLauncherError {
        XCTAssertEqual(error, .executableNotRegular)
    } catch {
        XCTFail("unexpected non-regular error")
    }

    // The executable's approved `.build` parent is part of the origin proof. A symlink there
    // must not redirect the launcher to an unrelated checkout or helper.
    try? FileManager.default.removeItem(at: root.appending(path: ".build"))
    let actualBuild = root.appending(path: "actual-build", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: actualBuild, withIntermediateDirectories: true)
    try localDaemonLauncherWrite(
        actualBuild.appending(path: "debug/aviaryd", directoryHint: .notDirectory),
        "#!/bin/sh\nexit 0\n", mode: mode_t(0o755))
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: ".build"), withDestinationURL: actualBuild)
    do {
        _ = try LocalAviaryDaemonLauncher(agentHome: home, sourceExecutableURL: source)
            .resolveExecutable()
        XCTFail("a symlinked .build parent must be rejected")
    } catch let error as LocalAviaryDaemonLauncherError {
        XCTAssertEqual(error, .executableSymlink)
    } catch {
        XCTFail("unexpected symlink-parent error")
    }
}

func testLocalAviaryDaemonLauncherValidatesExplicitPaths() throws {
    let root = try localDaemonLauncherScratch("paths")
    defer { try? FileManager.default.removeItem(at: root) }

    let missingHome = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    let source = localDaemonLauncherSource(root)
    let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let valid = try LocalAviaryDaemonLauncher(
        agentHome: missingHome, workspace: workspace, sourceExecutableURL: source)
    XCTAssertEqual(valid.workspace, workspace.standardizedFileURL)

    let workspaceTarget = root.appending(path: "workspace-target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceTarget, withIntermediateDirectories: true)
    let workspaceLink = root.appending(path: "workspace-link", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: workspaceLink, withDestinationURL: workspaceTarget)
    do {
        _ = try LocalAviaryDaemonLauncher(
            agentHome: missingHome, workspace: workspaceLink, sourceExecutableURL: source)
        XCTFail("an explicit symlink workspace must be rejected")
    } catch let error as LocalAviaryDaemonLauncherError {
        XCTAssertEqual(error, .invalidWorkspace)
    } catch {
        XCTFail("unexpected workspace error")
    }

    let homeTarget = root.appending(path: "home-target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: homeTarget, withIntermediateDirectories: true)
    let homeLink = root.appending(path: "home-link", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: homeTarget)
    do {
        _ = try LocalAviaryDaemonLauncher(
            agentHome: AgentHome(root: homeLink), sourceExecutableURL: source)
        XCTFail("an AgentHome symlink must be rejected")
    } catch let error as LocalAviaryDaemonLauncherError {
        XCTAssertEqual(error, .invalidAgentHome)
    } catch {
        XCTFail("unexpected AgentHome error")
    }
}

func testLocalAviaryDaemonLauncherSpawnsDetachedWithExactArguments() async throws {
    let root = try localDaemonLauncherScratch("spawn")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "agent-home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let logRoot = root.appending(path: "logs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: logRoot, withIntermediateDirectories: true)
    let argvLog = logRoot.appending(path: "argv", directoryHint: .notDirectory)
    let pidLog = logRoot.appending(path: "pid", directoryHint: .notDirectory)
    let fdLog = logRoot.appending(path: "fd", directoryHint: .notDirectory)
    let cwdLog = logRoot.appending(path: "cwd", directoryHint: .notDirectory)
    let doneLog = logRoot.appending(path: "done", directoryHint: .notDirectory)
    let body = """
    #!/bin/sh
    set -eu
    printf '%s\\n' "$@" > \(localDaemonLauncherShellQuote(argvLog.path))
    printf '%s\\n' "$$" > \(localDaemonLauncherShellQuote(pidLog.path))
    stat -f '%HT' /dev/fd/0 /dev/fd/1 /dev/fd/2 > \(localDaemonLauncherShellQuote(fdLog.path))
    pwd > \(localDaemonLauncherShellQuote(cwdLog.path))
    sleep 0.8
    : > \(localDaemonLauncherShellQuote(doneLog.path))
    """
    _ = try localDaemonLauncherExecutable(root, body: body)
    let source = localDaemonLauncherSource(root)
    let launchTask = Task { () throws -> Void in
        let launcher = try LocalAviaryDaemonLauncher(
            agentHome: AgentHome(root: home), workspace: workspace, sourceExecutableURL: source)
        try await launcher.launch()
        // Keep the client task alive after launch so the test can cancel it while the daemon
        // fixture is still running.  The launcher itself has no process-termination hook.
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    let started = Date()
    XCTAssertTrue(try await localDaemonLauncherWaitForFile(argvLog))
    XCTAssertTrue(Date().timeIntervalSince(started) < 0.4,
                  "launcher must return after spawn rather than wait for daemon exit")
    // `argv` is the fixture's first write. Its presence proves spawn, not that the following
    // PID/fd/cwd observations have all reached disk; wait for each independently so scheduler
    // load cannot turn an intentionally detached child into a test race.
    XCTAssertTrue(try await localDaemonLauncherWaitForFile(pidLog))
    XCTAssertTrue(try await localDaemonLauncherWaitForFile(fdLog))
    XCTAssertTrue(try await localDaemonLauncherWaitForFile(cwdLog))
    let expected = [
        "--agent-home", home.standardizedFileURL.path,
        "--workspace", workspace.standardizedFileURL.path,
    ]
    XCTAssertEqual(try localDaemonLauncherReadLines(argvLog), expected)
    let pid = try XCTUnwrap(Int32(
        try localDaemonLauncherReadLines(pidLog).first ?? ""))
    XCTAssertEqual(kill(pid, 0), 0, "child must still be alive when launch returns")
    let fdTypes = try localDaemonLauncherReadLines(fdLog)
    XCTAssertEqual(fdTypes.count, 3)
    XCTAssertFalse(fdTypes.contains("Fifo File"), "daemon stdio must not be a parent-owned pipe")
    XCTAssertEqual(try localDaemonLauncherReadLines(cwdLog), ["/"])

    // Canceling the client task and dropping its launcher are both client-side events; neither
    // is allowed to send a signal to the process which now owns the Work Host.
    launchTask.cancel()
    _ = try? await launchTask.value
    XCTAssertTrue(try await localDaemonLauncherWaitForFile(doneLog, timeout: 3),
                  "child must survive launcher/client cancellation")
    XCTAssertNotEqual(kill(pid, 0), 0, "fixture child must exit on its own")
}

let casesLocalAviaryDaemonLauncher: [Case] = [
    ("phase4 local aviaryd launcher resolves approved layouts", {
        try testLocalAviaryDaemonLauncherResolutionUsesApprovedPrecedence()
    }),
    ("phase4 local aviaryd launcher rejects unsafe executables", {
        try testLocalAviaryDaemonLauncherRejectsUnsafeCandidates()
    }),
    ("phase4 local aviaryd launcher validates explicit paths", {
        try testLocalAviaryDaemonLauncherValidatesExplicitPaths()
    }),
    ("phase4 local aviaryd launcher is detached and argument bounded", {
        try await testLocalAviaryDaemonLauncherSpawnsDetachedWithExactArguments()
    }),
]
