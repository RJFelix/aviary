import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import AviaryCore

private func daemonEndpointFixture(
    _ name: String
) throws -> (root: URL, home: AgentHome, host: WorkHostRef, layout: WorkHostDaemonEndpointLayout) {
    _ = name
    // Darwin's sockaddr_un path is only 103 bytes. Keep the whole fixture under a deliberately
    // short root so these tests exercise endpoint identity rather than an impossible caller path.
    let root = URL(
        fileURLWithPath: "/tmp/ade-\(UUID().uuidString.lowercased())",
        isDirectory: true)
    let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    let host = try home.requirePersistedWorkHost()
    let layout = WorkHostDaemonEndpointLayout(
        home: home,
        workHost: host,
        socketRoot: root.appending(path: "sockets", directoryHint: .isDirectory))
    return (root, home, host, layout)
}

func test_workHostDaemonEndpointPublishesBoundedNonLivenessDiscovery() throws {
    let fixture = try daemonEndpointFixture("publish")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let instance = WorkHostInstanceRef(
        host: fixture.host,
        instanceID: "instance-\(UUID().uuidString.lowercased())",
        startIdentity: "start-\(UUID().uuidString.lowercased())")
    let endpoint = try fixture.layout.endpoint(for: instance)
    let descriptor = WorkHostDaemonDescriptor(
        hostInstance: instance, endpoint: endpoint, processID: getpid(),
        publishedAt: Date(timeIntervalSince1970: 123))
    let publisher = try WorkHostDaemonEndpointPublisher(
        layout: fixture.layout, descriptor: descriptor)

    try publisher.publish()
    let discovered = try XCTUnwrap(
        WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout))
    XCTAssertEqual(discovered, descriptor)
    XCTAssertFalse(discovered.isLivenessProof)
    XCTAssertTrue(discovered.endpoint.path.hasPrefix(fixture.layout.socketRoot.path))
    XCTAssertTrue(
        discovered.endpoint.path.utf8.count
            <= WorkHostDaemonEndpointLimits.maximumUnixSocketPathBytes)

    let attributes = try FileManager.default.attributesOfItem(
        atPath: fixture.layout.socketRoot.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    XCTAssertEqual(permissions, 0o700)

    try publisher.removeIfOwned()
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout))
}

func test_workHostDaemonEndpointOldGenerationCannotRemoveReplacement() throws {
    let fixture = try daemonEndpointFixture("replacement")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    func publisher(_ label: String, processID: Int32) throws -> WorkHostDaemonEndpointPublisher {
        let instance = WorkHostInstanceRef(
            host: fixture.host,
            instanceID: "instance-\(label)",
            startIdentity: "start-\(label)")
        return try WorkHostDaemonEndpointPublisher(
            layout: fixture.layout,
            descriptor: WorkHostDaemonDescriptor(
                hostInstance: instance,
                endpoint: try fixture.layout.endpoint(for: instance),
                processID: processID,
                publishedAt: Date(timeIntervalSince1970: TimeInterval(processID))))
    }
    let old = try publisher("old", processID: 101)
    let replacement = try publisher("new", processID: 202)
    try old.publish()
    try replacement.publish()

    try old.removeIfOwned()
    XCTAssertEqual(
        try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout),
        replacement.descriptor,
        "an old process generation cannot remove the replacement endpoint")

    try replacement.removeIfOwned()
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout))
}

func test_workHostDaemonEndpointRejectsMalformedOversizedAndSymlinkedRecords() throws {
    let fixture = try daemonEndpointFixture("adversarial")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
        at: fixture.layout.descriptorDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: fixture.layout.descriptorDirectory.path)

    let oversized = Data(
        repeating: UInt8(ascii: "x"),
        count: WorkHostDaemonEndpointLimits.maximumDescriptorBytes + 1)
    try oversized.write(to: fixture.layout.descriptorURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: fixture.layout.descriptorURL.path)
    do {
        _ = try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout)
        XCTFail("oversized endpoint descriptors must fail before decoding")
    } catch WorkHostDaemonEndpointError.descriptorTooLarge {
        XCTAssertTrue(true)
    }

    try FileManager.default.removeItem(at: fixture.layout.descriptorURL)
    let target = fixture.root.appending(path: "target.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
        at: fixture.layout.descriptorURL, withDestinationURL: target)
    do {
        _ = try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout)
        XCTFail("a descriptor symlink must not be followed")
    } catch WorkHostDaemonEndpointError.accessDenied {
        XCTAssertTrue(true)
    }

    try FileManager.default.removeItem(at: fixture.layout.descriptorURL)
    let instance = WorkHostInstanceRef(
        host: fixture.host, instanceID: "instance-readable", startIdentity: "start-readable")
    let descriptor = WorkHostDaemonDescriptor(
        hostInstance: instance, endpoint: try fixture.layout.endpoint(for: instance),
        processID: 404)
    try JSONEncoder().encode(descriptor).write(to: fixture.layout.descriptorURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o644))],
        ofItemAtPath: fixture.layout.descriptorURL.path)
    do {
        _ = try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout)
        XCTFail("a group/world-readable endpoint descriptor must not be trusted")
    } catch WorkHostDaemonEndpointError.accessDenied {
        XCTAssertTrue(true)
    }
}

func test_workHostDaemonEndpointRefusesRatherThanChmodsSharedSocketRoot() throws {
    let fixture = try daemonEndpointFixture("permissions")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let shared = fixture.root.appending(path: "shared", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: shared, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: shared.path)
    let layout = WorkHostDaemonEndpointLayout(
        home: fixture.home, workHost: fixture.host, socketRoot: shared)
    let instance = WorkHostInstanceRef(
        host: fixture.host, instanceID: "instance-permissions",
        startIdentity: "start-permissions")
    do {
        _ = try layout.endpoint(for: instance)
        XCTFail("an existing group/world-accessible socket root must be refused")
    } catch WorkHostDaemonEndpointError.accessDenied {
        XCTAssertTrue(true)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: shared.path)
    XCTAssertEqual(
        (attributes[.posixPermissions] as? NSNumber)?.intValue,
        0o755,
        "endpoint discovery must not chmod an arbitrary shared directory")
}

func test_workHostDaemonEndpointDiscoveryRejectsSymlinkedDescriptorDirectory() throws {
    let fixture = try daemonEndpointFixture("descriptor-directory")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let replacement = fixture.root.appending(
        path: "descriptor-target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: replacement, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    try FileManager.default.createDirectory(
        at: fixture.layout.descriptorDirectory.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: fixture.layout.descriptorDirectory, withDestinationURL: replacement)
    do {
        _ = try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout)
        XCTFail("discovery must not follow a symlinked descriptor directory")
    } catch WorkHostDaemonEndpointError.accessDenied {
        XCTAssertTrue(true)
    }
}

func test_workHostDaemonEndpointDecoderCannotPromotePersistedLiveness() throws {
    let fixture = try daemonEndpointFixture("liveness")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let instance = WorkHostInstanceRef(
        host: fixture.host, instanceID: "instance-liveness", startIdentity: "start-liveness")
    let descriptor = WorkHostDaemonDescriptor(
        hostInstance: instance,
        endpoint: try fixture.layout.endpoint(for: instance),
        processID: 303,
        publishedAt: Date(timeIntervalSince1970: 456))
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
    object["isLivenessProof"] = true
    let bytes = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(WorkHostDaemonDescriptor.self, from: bytes)
    XCTAssertFalse(decoded.isLivenessProof)
    try decoded.validate(expectedHost: fixture.host)
}

func test_workHostDaemonEndpointDistinguishesUnsupportedProtocolFromMalformedDescriptor() throws {
    let fixture = try daemonEndpointFixture("protocol-fence")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let instance = WorkHostInstanceRef(
        host: fixture.host, instanceID: "instance-protocol-fence",
        startIdentity: "start-protocol-fence")
    let descriptor = WorkHostDaemonDescriptor(
        hostInstance: instance,
        endpoint: try fixture.layout.endpoint(for: instance),
        processID: 404,
        publishedAt: Date(timeIntervalSince1970: 789))
    let publisher = try WorkHostDaemonEndpointPublisher(
        layout: fixture.layout, descriptor: descriptor)
    try publisher.publish()

    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
    object["workServiceProtocolVersion"] = 4
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.layout.descriptorURL)
    let unsupported = try XCTUnwrap(
        WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout))
    XCTAssertEqual(unsupported.workServiceProtocolVersion, 4)
    XCTAssertEqual(unsupported.hostInstance, instance)
    try unsupported.validate(expectedHost: fixture.host)

    object["workServiceProtocolVersion"] = 0
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.layout.descriptorURL)
    do {
        _ = try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout)
        XCTFail("a nonpositive protocol version is a malformed descriptor, not a negotiable peer")
    } catch WorkHostDaemonEndpointError.invalidDescriptor {
        XCTAssertTrue(true)
    }
}

func test_workHostDaemonRuntimeSurvivesClientDisconnectAndAcceptsAnotherClient() async throws {
    let fixture = try daemonEndpointFixture("runtime")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstClient = ClientRef("gui-a")
    let secondClient = ClientRef("gui-b")
    let grants = Set(WorkServiceCapability.allCases)
    let service = InMemoryWorkService(
        host: fixture.host,
        instanceID: "instance-runtime",
        startIdentity: "start-runtime",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            firstClient: grants,
            secondClient: grants,
        ]))
    let hostInstance = WorkHostInstanceRef(
        host: fixture.host,
        instanceID: "instance-runtime",
        startIdentity: "start-runtime")
    let runtime = try WorkHostDaemonRuntime(
        home: fixture.home,
        hostInstance: hostInstance,
        service: service,
        socketRoot: fixture.layout.socketRoot)

    let descriptor = try await runtime.start()
    let runningState = await runtime.state
    XCTAssertEqual(runningState, .running)
    XCTAssertEqual(
        try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout), descriptor)

    let clientA = WorkServiceUnixSocketClient(
        endpoint: descriptor.endpoint, client: firstClient, expectedHost: fixture.host)
    let firstHandshake = try await clientA.connect(build: "gui-a")
    XCTAssertEqual(firstHandshake.hostInstance, hostInstance)
    await clientA.close()

    // EOF belongs to this connection only. The same daemon generation stays discoverable and a
    // second GUI can establish its own independent connection.
    let stateAfterDisconnect = await runtime.state
    XCTAssertEqual(stateAfterDisconnect, .running)
    XCTAssertEqual(
        try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout), descriptor)
    let clientB = WorkServiceUnixSocketClient(
        endpoint: descriptor.endpoint, client: secondClient, expectedHost: fixture.host)
    let secondHandshake = try await clientB.connect(build: "gui-b")
    XCTAssertEqual(secondHandshake.hostInstance, hostInstance)
    await clientB.close()

    await runtime.stop(drainTimeout: 0.2)
    let stoppedState = await runtime.state
    XCTAssertEqual(stoppedState, .stopped)
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout))
}

func test_workHostDaemonRuntimeRefusesMismatchedBackingServiceBeforePublication() async throws {
    let fixture = try daemonEndpointFixture("identity-mismatch")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = InMemoryWorkService(
        host: fixture.host,
        instanceID: "instance-service",
        startIdentity: "start-service",
        authorizer: WorkServiceCapabilityPolicy())
    let expected = WorkHostInstanceRef(
        host: fixture.host,
        instanceID: "instance-daemon",
        startIdentity: "start-daemon")
    let runtime = try WorkHostDaemonRuntime(
        home: fixture.home,
        hostInstance: expected,
        service: service,
        socketRoot: fixture.layout.socketRoot)
    do {
        _ = try await runtime.start()
        XCTFail("a daemon cannot publish a different backing service instance")
    } catch WorkHostDaemonRuntimeError.invalidServiceIdentity {
        XCTAssertTrue(true)
    }
    let failedState = await runtime.state
    XCTAssertEqual(failedState, .failed)
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(layout: fixture.layout))
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.endpoint.path))
    // A supervisor's final cleanup boundary must also absorb a failed startup. This is
    // intentionally a separate assertion from the no-publication proof: a future startup path
    // may have acquired a listener before reporting its failure.
    await runtime.stop()
    XCTAssertEqual(await runtime.state, .stopped)
}

let casesWorkHostDaemonEndpoint: [Case] = [
    ("phase3 Work Host endpoint: discovery is bounded and not liveness", {
        try test_workHostDaemonEndpointPublishesBoundedNonLivenessDiscovery()
    }),
    ("phase3 Work Host endpoint: old generation cannot delete replacement", {
        try test_workHostDaemonEndpointOldGenerationCannotRemoveReplacement()
    }),
    ("phase3 Work Host endpoint: malformed oversized and symlink records fail closed", {
        try test_workHostDaemonEndpointRejectsMalformedOversizedAndSymlinkedRecords()
    }),
    ("phase3 Work Host endpoint: persisted liveness assertion is ignored", {
        try test_workHostDaemonEndpointDecoderCannotPromotePersistedLiveness()
    }),
    ("phase5 Work Host endpoint: unsupported protocol remains structurally discoverable", {
        try test_workHostDaemonEndpointDistinguishesUnsupportedProtocolFromMalformedDescriptor()
    }),
    ("phase3 Work Host endpoint: shared socket roots are never chmod repaired", {
        try test_workHostDaemonEndpointRefusesRatherThanChmodsSharedSocketRoot()
    }),
    ("phase3 Work Host endpoint: symlinked descriptor directory fails closed", {
        try test_workHostDaemonEndpointDiscoveryRejectsSymlinkedDescriptorDirectory()
    }),
    ("phase3 Work Host daemon: client EOF does not stop the service", {
        try await test_workHostDaemonRuntimeSurvivesClientDisconnectAndAcceptsAnotherClient()
    }),
    ("phase3 Work Host daemon: backing service identity is fenced before publication", {
        try await test_workHostDaemonRuntimeRefusesMismatchedBackingServiceBeforePublication()
    }),
]
