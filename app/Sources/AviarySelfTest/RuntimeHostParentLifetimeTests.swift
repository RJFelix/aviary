import Darwin
import Foundation
@testable import AviaryCore

private func test_parentLifetimeLease(
    script: URL,
    root: URL,
    variant: String
) throws {
    let directory = root.appending(
        path: "al-\(variant.prefix(1))-\(UUID().uuidString.prefix(8))",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    guard Darwin.chmod(directory.path, mode_t(0o700)) == 0 else {
        throw NSError(domain: "AviarySelfTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not secure lease test directory"])
    }

    let socket = directory.appending(path: "host.sock")
    let hostID = "parent-lease-\(variant)-\(UUID().uuidString)"
    let pidFile = directory.appending(path: "host.pid")

    // A short-lived helper owns the Python host. Once it has observed the socket bind, it exits
    // without waiting. The host's parent therefore changes to launchd and its explicit PID lease
    // must terminate it. This exercises the same kernel-visible event as an abrupt SelfTest death.
    let helper = #"""
import os, subprocess, sys, time
script, socket_path, host_id, pid_path = sys.argv[1:]
child = subprocess.Popen([
    "python3", script, "--socket", socket_path, "--host-id", host_id,
    "--parent-lifetime-pid", str(os.getpid()),
], close_fds=True, stderr=open(pid_path + ".stderr", "wb"))
with open(pid_path, "w") as output:
    output.write(str(child.pid))
deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    if child.poll() is not None:
        raise SystemExit(2)
    if os.path.exists(socket_path):
        raise SystemExit(0)
    time.sleep(0.01)
child.kill()
raise SystemExit(3)
"""#

    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", "-c", helper,
        script.path, socket.path, hostID, pidFile.path,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let errorText = String(
        data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let childError = (try? String(
        contentsOf: pidFile.appendingPathExtension("stderr"), encoding: .utf8)) ?? ""
    XCTAssertEqual(process.terminationStatus, 0,
                   "\(variant) lease helper failed: \(errorText)\(childError)")

    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
    let childPID = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    let exitDeadline = Date().addingTimeInterval(5)
    while Darwin.kill(childPID, 0) == 0, Date() < exitDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertNotEqual(Darwin.kill(childPID, 0), 0,
                      "\(variant) host survived its parent lifetime lease")
    XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path),
                   "\(variant) lease left a stale runtime socket")
}

func test_runtimeHostParentLifetimeLeaseIsTestOnlyAndSymmetric() throws {
    guard let root = EngineLocator.repoRoot() else {
        print("      skipped: no repo root found")
        return
    }
    let temp = FileManager.default.temporaryDirectory
    for variant in ["python3", "python3-shared"] {
        let script = root.appending(path: "runtime-hosts/\(variant)/host.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            print("      skipped: \(script.lastPathComponent) missing for \(variant)")
            continue
        }
        try test_parentLifetimeLease(script: script, root: temp, variant: variant)
    }
}

let casesRuntimeHostParentLifetime: [Case] = [
    ("phase1 runtime host: test parent lease cleans up both Python hosts", {
        try test_runtimeHostParentLifetimeLeaseIsTestOnlyAndSymmetric()
    }),
]
