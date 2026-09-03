import Foundation
import Darwin
@testable import AviaryCore

private final class AdoptionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if open {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        guard !open else {
            lock.unlock()
            return
        }
        open = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}

private final class CallbackDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [(rid: String, client: String)] = []

    func record(rid: String, client: String) {
        lock.lock()
        deliveries.append((rid: rid, client: client))
        lock.unlock()
    }

    var snapshot: [(rid: String, client: String)] {
        lock.lock(); defer { lock.unlock() }
        return deliveries
    }
}

private func runtimeHostAdoptionDescriptor(
    _ host: RuntimeHost
) async throws -> RuntimeHost.AdoptionDescriptor {
    try XCTUnwrap(await host.adoptionDescriptor)
}

private func callbackResolutionProbe(
    endpoint: RuntimeHost.SocketEndpoint,
    identity: RuntimeHost.HostIdentity,
    callbackRID: String
) throws -> [JSONValue] {
    let source = #"""
import json, socket, sys
path, host_id, instance_id, callback_rid = sys.argv[1:]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
sock.connect(path)
reader = sock.makefile("rb")

def read_message():
    line = reader.readline()
    if not line:
        raise RuntimeError("host closed before probe response")
    return json.loads(line)

read_message()  # ready
sock.sendall((json.dumps({
    "id": "probe-hello",
    "op": "hello",
    "protocol": 3,
    "expectedIdentity": {"hostID": host_id, "instanceID": instance_id},
}) + "\n").encode())
read_message()
for index, rid in enumerate((callback_rid, "missing-callback")):
    sock.sendall((json.dumps({
        "id": "probe-result-" + str(index),
        "op": "callback.result",
        "rid": rid,
        "result": {"answer": "late"},
    }) + "\n").encode())
    print(json.dumps(read_message()), flush=True)
"""#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", "-c", source, endpoint.path, identity.hostID, identity.instanceID, callbackRID,
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw UnwrapFailure(description: "callback resolution probe failed")
    }
    return data.split(separator: 0x0a).compactMap {
        JSONValue.parse(Data($0))
    }
}

private func unreadPythonClientProbe(script: URL) throws -> JSONValue {
    let source = #"""
import importlib.util, json, socket, sys, threading, time
spec = importlib.util.spec_from_file_location("aviary_runtime_host_probe", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sender, peer = socket.socketpair()
sender.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
reader = sender.makefile("rb")
reader_exited = threading.Event()
def blocked_read():
    try:
        reader.readline()
    finally:
        reader_exited.set()
thread = threading.Thread(target=blocked_read, daemon=True)
thread.start()
client = module.Client(sender)
started = time.monotonic()
sent = client.send_obj({"event": "output", "text": "x" * (1024 * 1024)})
elapsed = time.monotonic() - started
thread.join(2)
print(json.dumps({
    "sent": sent,
    "closed": client.closed,
    "readerExited": reader_exited.is_set(),
    "elapsedMilliseconds": int(elapsed * 1000),
}), flush=True)
peer.close()
reader.close()
"""#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-B", "-c", source, script.path]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        throw UnwrapFailure(description: "Python runtime Client remained blocked on an unread peer")
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0, let line = data.split(separator: 0x0a).last,
          let result = JSONValue.parse(Data(line))
    else {
        let detail = String(data: errorData, encoding: .utf8) ?? "no Python diagnostic"
        throw UnwrapFailure(description: "unread-client probe failed: \(detail)")
    }
    return result
}

private func launchUnreadRuntimeHost(
    endpoint: RuntimeHost.SocketEndpoint,
    identity: RuntimeHost.HostIdentity
) throws -> Process {
    let source = #"""
import json, os, socket, sys, time
path, host_id, instance_id = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
os.chmod(path, 0o600)
server.listen(1)
connection, _ = server.accept()
connection.sendall((json.dumps({
    "event": "ready",
    "protocol": 3,
    "runtime": "unreadable-peer",
    "runtimeVersion": "test",
    "hostID": host_id,
    "instanceID": instance_id,
    "transport": "unix",
    "features": {},
}) + "\n").encode())
time.sleep(5)
"""#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", "-c", source, endpoint.path, identity.hostID, identity.instanceID,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func test_runtimeHostNamespaceSurvivesClientDisconnectAndAdoption() async throws {
    guard let first = try makeHost(.reference) else { return }
    _ = try await first.start()
    let session = try await first.createSession(id: "adoptable")
    _ = try await first.execute("persisted = 'survives'", in: session)
    let descriptor = try await runtimeHostAdoptionDescriptor(first)
    XCTAssertTrue(
        descriptor.endpoint.path.utf8.count < 84,
        "generated endpoint should leave substantial Darwin sun_path headroom")

    await first.disconnect()
    XCTAssertFalse(await first.isConnected)

    // Reconnecting the same client must consume a fresh ready frame. In particular, it must not
    // return the capabilities cached before disconnect and then try to use a closed socket.
    let refreshed = try await first.reconnect(timeout: 2)
    XCTAssertEqual(refreshed.identity, descriptor.identity)
    XCTAssertTrue(await first.isConnected)
    XCTAssertEqual(try await first.sessions(), [session])
    let sameClientResult = try await first.execute("persisted", in: session)
    XCTAssertEqual(sameClientResult.value, "'survives'")

    // A later GUI can still adopt the same process after the original client reconnects and
    // disconnects again.
    await first.disconnect()

    let second = try RuntimeHost.adopt(descriptor)
    let caps = try await second.connect()
    XCTAssertEqual(caps.protocolVersion, RuntimeHost.protocolVersion)
    XCTAssertEqual(caps.identity, descriptor.identity)
    XCTAssertEqual(try await second.sessions(), [session])
    XCTAssertTrue(try await second.attachSession(session))
    let result = try await second.execute("persisted", in: session)
    XCTAssertEqual(result.value, "'survives'")

    // `stop` is explicit host shutdown. It is not the same operation as the disconnect above.
    await second.stop()
    let after = try RuntimeHost.adopt(descriptor)
    do {
        _ = try await after.connect(timeout: 0.3)
        XCTFail("a host that received explicit shutdown remained adoptable")
    } catch let error as RuntimeHost.HostError {
        if case .connectionFailed = error {
            // Expected: shutdown removes the endpoint and ends the process.
        } else {
            XCTFail("expected bounded connection failure after shutdown, got \(error)")
        }
    }
}

func test_runtimeHostAdoptionRejectsWrongIdentityProtocolAndPath() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let descriptor = try await runtimeHostAdoptionDescriptor(host)

    let wrongIdentity = try RuntimeHost.adopt(.init(
        endpoint: descriptor.endpoint,
        identity: .init(hostID: "different-host", instanceID: descriptor.identity.instanceID)))
    do {
        _ = try await wrongIdentity.connect(timeout: 1)
        XCTFail("adoption accepted a different host identity")
    } catch let error as RuntimeHost.HostError {
        guard case .identityMismatch = error else {
            XCTFail("expected identity mismatch, got \(error)")
            return
        }
    }

    do {
        _ = try RuntimeHost.adopt(.init(
            endpoint: descriptor.endpoint, identity: descriptor.identity, protocolVersion: 2))
        XCTFail("adoption accepted a descriptor for another protocol")
    } catch let error as RuntimeHost.HostError {
        guard case .adoptionDescriptorMismatch = error else {
            XCTFail("expected descriptor protocol mismatch, got \(error)")
            return
        }
    }

    let wrongPath = RuntimeHost(
        endpoint: .init(path: "/tmp/aviary-missing-runtime-host-\(UUID().uuidString)"),
        expectedIdentity: descriptor.identity)
    do {
        _ = try await wrongPath.connect(timeout: 0.2)
        XCTFail("adoption accepted a missing socket")
    } catch let error as RuntimeHost.HostError {
        guard case .connectionFailed = error else {
            XCTFail("expected bounded path connection failure, got \(error)")
            return
        }
    }

    let longPath = RuntimeHost(
        endpoint: .init(path: "/tmp/\(String(repeating: "x", count: 120))"),
        expectedIdentity: descriptor.identity)
    do {
        _ = try await longPath.connect(timeout: 0.2)
        XCTFail("adoption accepted a path beyond Darwin's sockaddr_un limit")
    } catch let error as RuntimeHost.HostError {
        guard case .invalidEndpoint = error else {
            XCTFail("expected bounded long-path rejection, got \(error)")
            return
        }
    }
    await host.stop()
}

func test_runtimeHostOwnedProcessCanRestartWithFreshIdentity() async throws {
    guard let host = try makeHost(.reference) else { return }
    let firstCapabilities = try await host.start()
    let firstIdentity = try XCTUnwrap(firstCapabilities.identity)
    XCTAssertEqual(await host.hostIdentity, firstIdentity)

    await host.stop()
    XCTAssertNil(await host.hostIdentity)
    XCTAssertNil(await host.endpoint)

    let secondCapabilities = try await host.start()
    let secondIdentity = try XCTUnwrap(secondCapabilities.identity)
    XCTAssertNotEqual(secondIdentity, firstIdentity, "restart adopted the stopped process identity")
    XCTAssertEqual(await host.hostIdentity, secondIdentity)
    XCTAssertTrue(await host.isConnected)
    await host.stop()
}

func test_runtimeHostCancellationRemovesPendingRequest() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-cancel-pending-\(String(UUID().uuidString.prefix(8)))",
                   directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = RuntimeHost.SocketEndpoint(path: root.appending(path: "host.sock").path)
    let identity = RuntimeHost.HostIdentity(hostID: "cancel-pending", instanceID: "instance")
    let process = try launchUnreadRuntimeHost(endpoint: endpoint, identity: identity)
    defer {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    let host = RuntimeHost(endpoint: endpoint, expectedIdentity: identity)
    _ = try await host.connect(timeout: 2)
    let request = Task {
        try await host.execute("1 + 1", in: "cancel-pending-session", timeout: 30)
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    let canceledAt = Date()
    request.cancel()
    do {
        _ = try await request.value
        XCTFail("a canceled request unexpectedly produced a result")
    } catch is CancellationError {
        // The caller's cancellation is the operation's truthful outcome.
    } catch {
        XCTFail("expected CancellationError after cancel, got \(error)")
    }
    XCTAssertTrue(
        Date().timeIntervalSince(canceledAt) < 1,
        "canceled request remained pending until transport timeout/close")
    await host.disconnect()
}

func test_runtimeHostDestroyRecreateSameSessionKeepsNewAttachment() async throws {
    for variant in [HostVariant.reference, .shared] {
        guard let first = try makeHost(variant) else { continue }
        _ = try await first.start()
        let descriptor = try await runtimeHostAdoptionDescriptor(first)
        let session = "destroy-recreate-\(variant.rawValue)"
        _ = try await first.createSession(id: session)

        let second = try RuntimeHost.adopt(descriptor)
        _ = try await second.connect()
        let callbackStarted = AdoptionLatch()
        await first.onCallback { _, _, _, _ in
            callbackStarted.signal()
            return .object(["answer": .string("new-session-client")])
        }

        // The host removes the old session and its client attachment atomically. Recreate the
        // same ID while the old Session's worker is still closing; a non-atomic implementation
        // can delete the newly-created mapping after create has attached it.
        let destroy = Task { try await second.destroySession(session) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let recreate = Task { try await first.createSession(id: session) }
        _ = try await destroy.value
        if (try? await recreate.value) == nil {
            _ = try await first.createSession(id: session)
        }

        let result = try await first.execute(
            "ask_app('destroy-recreate')", in: session, timeout: 3)
        await callbackStarted.wait()
        XCTAssertEqual(result.value, "{'answer': 'new-session-client'}")
        await second.disconnect()
        await first.stop()
    }
}

private struct RuntimeHostStartupObservation {
    let status: Int32
    let stayedAlive: Bool
}

private func runRuntimeHostStartup(
    script: URL, socket: URL, hostID: String
) throws -> RuntimeHostStartupObservation {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", script.path, "--socket", socket.path, "--host-id", hostID,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()

    // A bind-policy failure should be immediate. Keep this bounded so a regression that
    // accidentally starts a second live host cannot hang the self-test indefinitely.
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    let stayedAlive = process.isRunning
    if stayedAlive {
        // Ask the host to leave its serve loop so its normal socket cleanup runs. This is a
        // bounded probe, not the lifecycle operation under test; explicit protocol shutdown is
        // covered by the adoption test above.
        _ = Darwin.kill(process.processIdentifier, SIGINT)
        let gracefulDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    return RuntimeHostStartupObservation(
        status: process.terminationStatus, stayedAlive: stayedAlive)
}

private func createStaleRuntimeSocket(_ socket: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", "-c",
        "import socket, sys; listener = socket.socket(socket.AF_UNIX); listener.bind(sys.argv[1]); listener.close()",
        socket.path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UnwrapFailure(description: "could not create stale runtime socket")
    }
}

func test_runtimeHostSocketPathPolicyPreservesOccupiedEndpoints() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let root = try XCTUnwrap(EngineLocator.repoRoot())
    let script = root.appending(path: "runtime-hosts/python3/host.py")
    // AF_UNIX paths are capped at 103 bytes on Darwin. Keep the unique temporary directory
    // component short enough that the socket path remains valid even under a long temp root.
    let shortID = String(UUID().uuidString.prefix(8))
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "aviary-bind-\(shortID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)

    // A regular file is never a stale socket and must not be removed to make room for one.
    let regular = directory.appending(path: "occupied")
    let original = Data("keep-this-file".utf8)
    try original.write(to: regular)
    let regularObservation = try runRuntimeHostStartup(
        script: script, socket: regular, hostID: "path-policy-regular")
    XCTAssertNotEqual(regularObservation.status, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: regular.path))
    XCTAssertEqual(FileManager.default.contents(atPath: regular.path), original)

    // The host also refuses to repair an insecure parent. This keeps the policy from falling
    // back to chmod-ing a shared directory such as /tmp just to make a socket bindable.
    let insecureDirectory = directory.appending(path: "insecure", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: insecureDirectory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: insecureDirectory.path)
    let insecureSocket = insecureDirectory.appending(path: "host.sock")
    let insecureObservation = try runRuntimeHostStartup(
        script: script, socket: insecureSocket, hostID: "path-policy-insecure-parent")
    XCTAssertNotEqual(insecureObservation.status, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: insecureSocket.path))
    let insecureMode = try FileManager.default.attributesOfItem(
        atPath: insecureDirectory.path)[.posixPermissions] as? Int
    XCTAssertEqual(insecureMode, 0o755)

    // A closed socket inode is the one occupied endpoint that may be reclaimed. The host must
    // prove it is stale first, then remain alive on the newly bound socket until this bounded
    // probe terminates it.
    let stale = directory.appending(path: "stale.sock")
    try createStaleRuntimeSocket(stale)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    let staleObservation = try runRuntimeHostStartup(
        script: script, socket: stale, hostID: "path-policy-stale")
    XCTAssertTrue(staleObservation.stayedAlive)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))

    // A live host is likewise never replaced by another process at the same endpoint.
    let liveEndpoint = try XCTUnwrap(await host.endpoint)
    let live = URL(fileURLWithPath: liveEndpoint.path)
    let liveObservation = try runRuntimeHostStartup(
        script: script, socket: live, hostID: "path-policy-live")
    XCTAssertNotEqual(liveObservation.status, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    await host.stop()
}

func test_runtimeHostKernelDirectoryRefusesSymlinkWithoutMutatingTarget() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-kernel-dir-\(String(UUID().uuidString.prefix(8)))",
                   directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let target = root.appending(path: "target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: target.path)
    let link = root.appending(path: "kernels", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    do {
        _ = try RuntimeHost.secureKernelSocketDirectory(at: link)
        XCTFail("the launcher followed a symlinked kernel directory")
    } catch let error as RuntimeHost.HostError {
        guard case .invalidEndpoint = error else {
            XCTFail("expected an invalid endpoint for a symlinked directory, got (error)")
            return
        }
    }
    let targetMode = try FileManager.default.attributesOfItem(
        atPath: target.path)[.posixPermissions] as? Int
    XCTAssertEqual(targetMode, 0o755)
}

func test_runtimeHostOversizedResponseCompletesWithBoundedFailure() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    let session = try await host.createSession(id: "oversized-response")

    // The client rejects an oversized request before registering or writing it. The typed
    // operation/size error is its correlation; no malformed partial request reaches Python.
    do {
        _ = try await host.execute(
            String(repeating: "x", count: RuntimeHost.maxFrameBytes), in: session, timeout: 0)
        XCTFail("an oversized outbound request was accepted")
    } catch let error as RuntimeHost.HostError {
        guard case .frameTooLarge(let op, let bytes, let limit) = error else {
            XCTFail("expected typed outbound frame rejection, got \(error)")
            await host.stop()
            return
        }
        XCTAssertEqual(op, "exec")
        XCTAssertTrue(bytes > limit)
        XCTAssertEqual(limit, RuntimeHost.maxFrameBytes)
    }

    // A zero timeout must settle without the old registration Task race, and its late reply must
    // not poison the connection. Depending on scheduling, the tiny request may either win or
    // lose the race; both outcomes are valid, but neither may hang or make the next request fail.
    let zeroTimeoutStart = Date()
    do {
        _ = try await host.execute("1 + 1", in: session, timeout: 0)
    } catch let error as RuntimeHost.HostError {
        guard case .timedOut(let op) = error else {
            XCTFail("expected zero-timeout request to settle, got \(error)")
            await host.stop()
            return
        }
        XCTAssertEqual(op, "exec")
    }
    XCTAssertTrue(Date().timeIntervalSince(zeroTimeoutStart) < 1)
    let usable = try await host.execute("40 + 2", in: session, timeout: 2)
    XCTAssertEqual(usable.value, "42")

    do {
        _ = try await host.execute("'x' * (4 * 1024 * 1024)", in: session, timeout: 2)
        XCTFail("an oversized response was accepted")
    } catch let error as RuntimeHost.HostError {
        guard case .rejected(let code, _) = error else {
            XCTFail("expected bounded response rejection, got \(error)")
            await host.stop()
            return
        }
        XCTAssertEqual(code, "response_too_large")
    }
    await host.stop()
}

func test_runtimeHostOversizedCallbackResolvesLocally() async throws {
    for variant in [HostVariant.reference, .shared] {
        guard let host = try makeHost(variant) else { continue }
        _ = try await host.start()
        let session = try await host.createSession(id: "oversized-callback-\(variant.rawValue)")
        let started = Date()
        let result = try await host.execute(
            "ask_app('oversized-callback', data='x' * \(RuntimeHost.maxFrameBytes))",
            in: session, timeout: 4)
        XCTAssertNil(result.exception)
        XCTAssertTrue(
            result.value?.contains("callback payload exceeded the runtime frame limit") == true,
            "oversized callback did not resolve its waiting Python call")
        XCTAssertTrue(
            Date().timeIntervalSince(started) < 3,
            "oversized callback waited for the ordinary 900-second callback timeout")
        await host.stop()
    }
}

func test_runtimeHostWriteAndDisconnectStayBoundedWhenPeerDoesNotRead() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-unread-peer-\(String(UUID().uuidString.prefix(8)))",
                   directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
    let endpoint = RuntimeHost.SocketEndpoint(path: root.appending(path: "host.sock").path)
    let identity = RuntimeHost.HostIdentity(hostID: "unread-peer", instanceID: "instance")
    let process = try launchUnreadRuntimeHost(endpoint: endpoint, identity: identity)
    defer {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    let host = RuntimeHost(endpoint: endpoint, expectedIdentity: identity)
    _ = try await host.connect(timeout: 2)
    let started = Date()
    do {
        _ = try await host.execute(
            String(repeating: "x", count: RuntimeHost.maxFrameBytes - 50_000),
            in: "unread-peer-session", timeout: 2)
        XCTFail("a peer that never reads unexpectedly returned a result")
    } catch let error as RuntimeHost.HostError {
        switch error {
        case .transportWriteFailed(let op, _), .timedOut(let op):
            XCTAssertEqual(op, "exec")
        default:
            XCTFail("expected bounded write/response failure, got \(error)")
        }
    }
    let writeElapsed = Date().timeIntervalSince(started)
    XCTAssertTrue(writeElapsed < 3, "write/response path took \(writeElapsed)s")

    let disconnectStarted = Date()
    await host.disconnect()
    XCTAssertTrue(Date().timeIntervalSince(disconnectStarted) < 1)
    XCTAssertFalse(await host.isConnected)
}

func test_runtimePythonHostsCloseUnreadClientsAndWakeReaders() throws {
    let root = try XCTUnwrap(EngineLocator.repoRoot())
    for variant in [HostVariant.reference, .shared] {
        let script = root.appending(path: "runtime-hosts/\(variant.rawValue)/host.py")
        let result = try unreadPythonClientProbe(script: script)
        XCTAssertEqual(result["sent"]?.boolValue, false, "\(variant.rawValue) claimed delivery")
        XCTAssertEqual(result["closed"]?.boolValue, true, "\(variant.rawValue) left Client open")
        XCTAssertEqual(
            result["readerExited"]?.boolValue, true,
            "\(variant.rawValue) did not wake its makefile reader")
        let elapsed = try XCTUnwrap(result["elapsedMilliseconds"]?.intValue)
        XCTAssertTrue(elapsed < 2_500, "\(variant.rawValue) blocked for \(elapsed)ms")
    }
}

func test_runtimeHostFramingDropsOversizedRecordsAndResynchronizes() {
    let framer = LineFramer(maxLineBytes: 8)
    XCTAssertEqual(framer.feed(Data("123456789".utf8)), [])
    XCTAssertEqual(framer.takeOverflowCount(), 1)
    let recovered = framer.feed(Data("discarded\nok\n".utf8)).compactMap {
        String(data: $0, encoding: .utf8)
    }
    XCTAssertEqual(recovered, ["ok"])
    XCTAssertEqual(framer.takeOverflowCount(), 0)
    XCTAssertEqual(
        framer.feed(Data("12345678\n".utf8)).compactMap {
            String(data: $0, encoding: .utf8)
        }, ["12345678"])
}

func test_runtimeHostSerializesSessionSubmitAndDestroy() async throws {
    for variant in [HostVariant.reference, .shared] {
        guard let host = try makeHost(variant) else { continue }
        _ = try await host.start()

        // The host receives both requests on one client, but the Python dispatcher and the
        // session worker are different threads. Exercise both linearizations repeatedly: once
        // submit wins, the queued job must run before the teardown marker; once destroy wins,
        // submit must receive a bounded session_closed/no_session response instead of landing
        // behind a dead interpreter.
        for index in 0..<4 {
            let session = try await host.createSession(id: "submit-destroy-\(index)")
            let execution = Task {
                try await host.execute(
                    "import time; time.sleep(0.02); 'finished'", in: session, timeout: 2)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            let destruction = Task { try await host.destroySession(session) }
            let executionResult = try await execution.value
            XCTAssertEqual(executionResult.value, "'finished'")
            _ = try await destruction.value
        }

        for index in 4..<8 {
            let session = try await host.createSession(id: "destroy-submit-\(index)")
            let destruction = Task { try await host.destroySession(session) }
            try await Task.sleep(nanoseconds: 10_000_000)
            do {
                let result = try await host.execute("'late'", in: session, timeout: 2)
                // If the request was already admitted before destroy acquired the session lock,
                // it is a valid first linearization. It must still complete and never be
                // stranded.
                XCTAssertEqual(result.value, "'late'")
            } catch let error as RuntimeHost.HostError {
                guard case .rejected(let code, _) = error,
                      code == "no_session" || code == "session_closed"
                else {
                    XCTFail("unexpected exec/destroy race outcome: \(error)")
                    _ = try? await destruction.value
                    await host.stop()
                    return
                }
            }
            _ = try await destruction.value
        }
        await host.stop()
    }
}

func test_runtimeHostCallbacksReplayAfterDisconnectAndReconnect() async throws {
    guard let first = try makeHost(.reference) else { return }
    _ = try await first.start()
    let session = try await first.createSession(id: "callback-adopt")
    let callbackStarted = AdoptionLatch()
    let releaseOldClient = AdoptionLatch()
    let deliveries = CallbackDeliveryRecorder()
    await first.onCallback { _, rid, _, _ in
        deliveries.record(rid: rid, client: "original")
        callbackStarted.signal()
        await releaseOldClient.wait()
        return .object(["answer": .string("old-client")])
    }

    // The first client has admitted the callback, but its handler is deliberately held open.
    // Disconnecting now leaves the host's callback identity pending for a future attachment.
    let oldExecution = Task {
        try await first.execute("callback_answer = ask_app('adopt')", in: session)
    }
    await callbackStarted.wait()
    let descriptor = try await runtimeHostAdoptionDescriptor(first)
    await first.disconnect()

    let second = try RuntimeHost.adopt(descriptor)
    await second.onCallback { _, rid, _, _ in
        deliveries.record(rid: rid, client: "reattached")
        return .object(["answer": .string("reattached-client")])
    }
    _ = try await second.connect()
    XCTAssertTrue(try await second.attachSession(session))

    // The old request's response was addressed to the disconnected socket, but its Python
    // state still completes. A new request can observe the callback result in that same
    // namespace, which proves replay rather than merely proving that attach returned.
    let observed = try await second.execute("callback_answer", in: session)
    XCTAssertEqual(observed.value, "{'answer': 'reattached-client'}")

    // Replay is intentionally at-least-once: both clients can run the handler for one stable
    // rid when the first client loses its response. Consumers must deduplicate durable effects
    // by rid; the transport cannot promise exactly-once across disconnects or crashes.
    let recorded = deliveries.snapshot
    XCTAssertEqual(recorded.count, 2)
    guard let firstDelivery = recorded.first else {
        XCTFail("callback replay did not deliver a callback")
        releaseOldClient.signal()
        _ = try? await oldExecution.value
        await second.stop()
        return
    }
    XCTAssertEqual(recorded.map(\.rid), [firstDelivery.rid, firstDelivery.rid])
    XCTAssertEqual(recorded.map(\.client), ["original", "reattached"])
    let resolutionLines = try callbackResolutionProbe(
        endpoint: descriptor.endpoint, identity: descriptor.identity, callbackRID: firstDelivery.rid)
    XCTAssertEqual(resolutionLines.count, 2)
    XCTAssertEqual(resolutionLines[0].path("data.delivered")?.boolValue, false)
    XCTAssertEqual(resolutionLines[0].path("data.status")?.stringValue, "duplicate")
    XCTAssertEqual(resolutionLines[1].path("data.delivered")?.boolValue, false)
    XCTAssertEqual(resolutionLines[1].path("data.status")?.stringValue, "stale")
    _ = try? await oldExecution.value

    releaseOldClient.signal()
    await second.stop()
}

let casesRuntimeHostAdoption: [Case] = [
    ("runtimeHost adoption: namespace survives disconnect and explicit shutdown", {
        try await test_runtimeHostNamespaceSurvivesClientDisconnectAndAdoption()
    }),
    ("runtimeHost adoption: wrong identity, protocol, and path fail explicitly", {
        try await test_runtimeHostAdoptionRejectsWrongIdentityProtocolAndPath()
    }),
    ("runtimeHost adoption: owned hosts restart with a fresh identity", {
        try await test_runtimeHostOwnedProcessCanRestartWithFreshIdentity()
    }),
    ("runtimeHost adoption: canceled requests remove pending continuations", {
        try await test_runtimeHostCancellationRemovesPendingRequest()
    }),
    ("runtimeHost adoption: destroy and recreate preserves the new attachment", {
        try await test_runtimeHostDestroyRecreateSameSessionKeepsNewAttachment()
    }),
    ("runtimeHost adoption: callbacks replay after disconnect and reconnect", {
        try await test_runtimeHostCallbacksReplayAfterDisconnectAndReconnect()
    }),
    ("runtimeHost adoption: occupied socket paths are preserved", {
        try await test_runtimeHostSocketPathPolicyPreservesOccupiedEndpoints()
    }),
    ("runtimeHost adoption: kernel directory symlinks are refused safely", {
        try test_runtimeHostKernelDirectoryRefusesSymlinkWithoutMutatingTarget()
    }),
    ("runtimeHost adoption: oversized responses complete with bounded failure", {
        try await test_runtimeHostOversizedResponseCompletesWithBoundedFailure()
    }),
    ("runtimeHost adoption: oversized callbacks resolve locally", {
        try await test_runtimeHostOversizedCallbackResolvesLocally()
    }),
    ("runtimeHost adoption: writes and disconnect stay bounded on an unread peer", {
        try await test_runtimeHostWriteAndDisconnectStayBoundedWhenPeerDoesNotRead()
    }),
    ("runtimeHost adoption: Python hosts close unread clients and wake readers", {
        try test_runtimePythonHostsCloseUnreadClientsAndWakeReaders()
    }),
    ("runtimeHost adoption: framing bounds and resynchronizes", {
        test_runtimeHostFramingDropsOversizedRecordsAndResynchronizes()
    }),
    ("runtimeHost adoption: session submit and destroy are serialized", {
        try await test_runtimeHostSerializesSessionSubmitAndDestroy()
    }),
]
