import Foundation
@testable import AviaryCore

private func workServiceLocatorScratchHome() throws -> (AgentHome, URL) {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-work-service-locator-" + UUID().uuidString,
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (AgentHome(root: root), root)
}

func testWorkServiceHostLocatorProjectsOnlyHandshakeIdentity() async throws {
    let (home, root) = try workServiceLocatorScratchHome()
    let socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(
        path: "aviary-wsl-" + String(UUID().uuidString.lowercased().prefix(8)),
        directoryHint: .isDirectory)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: socketRoot)
    }
    let host = try home.requirePersistedWorkHost()
    let layout = WorkHostDaemonEndpointLayout(
        home: home, workHost: host, socketRoot: socketRoot)
    let instance = WorkHostInstanceRef(
        host: host, instanceID: "instance-locator", startIdentity: "start-locator")
    let endpoint = try layout.endpoint(for: instance)
    let descriptor = WorkHostDaemonDescriptor(
        hostInstance: instance, endpoint: endpoint, processID: 42,
        publishedAt: Date(timeIntervalSince1970: 123))
    try WorkHostDaemonEndpointPublisher(layout: layout, descriptor: descriptor).publish()

    let located = try await LocalWorkServiceHostLocator(layout: layout).locate()
    XCTAssertEqual(located?.host, host)
    XCTAssertEqual(located?.expectedInstance, instance)
    XCTAssertEqual(located?.protocolVersion, WorkServiceProtocol.currentVersion)
    XCTAssertEqual(located?.transport, .unixSocket(endpoint))
}

func testWorkServiceHostLocatorMissingDescriptorIsUnavailable() async throws {
    let (home, root) = try workServiceLocatorScratchHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try home.requirePersistedWorkHost()
    let layout = WorkHostDaemonEndpointLayout(
        home: home, workHost: host,
        socketRoot: root.appending(path: "private-sockets", directoryHint: .isDirectory))

    XCTAssertNil(try await LocalWorkServiceHostLocator(layout: layout).locate())
}

let casesWorkServiceHostLocator: [Case] = [
    ("phase3 Work service locator projects handshake identity only", {
        try await testWorkServiceHostLocatorProjectsOnlyHandshakeIdentity()
    }),
    ("phase3 Work service locator reports missing descriptor as unavailable", {
        try await testWorkServiceHostLocatorMissingDescriptorIsUnavailable()
    }),
]
