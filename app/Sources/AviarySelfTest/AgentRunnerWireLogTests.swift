import Foundation
@testable import AviaryCore

private final class AgentRunnerWireLogProvider: ChatProvider, @unchecked Sendable {
    let id = "fake"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.requestBody(.object(["model": .string("test-model")])))
            continuation.yield(.textDelta("wire-log runner response"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private func runAgentRunnerRecordingFixture(
    home: AgentHome, host: RuntimeHost, wireLogURL: URL
) async throws {
    let hostID = try home.requirePersistedWorkHostID()
    let runID = "wire-log-safety-\(UUID().uuidString.lowercased())"
    let identity = SessionWorkIdentity(
        sessionID: "\(runID)-session",
        work: WorkRef(workHostID: hostID, workID: "\(runID)-work"),
        runID: runID)
    let runner = AgentRunner(
        provider: AgentRunnerWireLogProvider(), host: host,
        settings: .init(
            home: home, cwd: home.root.path, model: fakeModel(),
            systemPrompt: "wire-log safety fixture", recordPayloads: true,
            wireLogURL: wireLogURL, identity: identity))
    let prepared = try await runner.run(prompt: "attempt a best-effort wire log append")
    try await prepared.writer.closeChecked()
}

func testAgentRunnerRecordsAtConfiguredWireLogURL() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    defer { Task { await host.stop() } }

    let hostID = try home.requirePersistedWorkHostID()
    let runID = "wire-log-runner-\(UUID().uuidString.lowercased())"
    let identity = SessionWorkIdentity(
        sessionID: "\(runID)-session",
        work: WorkRef(workHostID: hostID, workID: "\(runID)-work"),
        runID: runID)
    let configuredURL = home.root.appending(path: "custom-wire/custom.jsonl")
    let defaultURL = WireLog.path(forRun: runID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: defaultURL.path))

    let runner = AgentRunner(
        provider: AgentRunnerWireLogProvider(), host: host,
        settings: .init(
            home: home, cwd: home.root.path, model: fakeModel(),
            systemPrompt: "wire-log runner fixture", recordPayloads: true,
            wireLogURL: configuredURL, identity: identity))
    let prepared = try await runner.run(prompt: "record at the configured path")
    try await prepared.writer.closeChecked()

    let records = WireLog.read(url: configuredURL)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.kind, .request)
    XCTAssertTrue(FileManager.default.fileExists(atPath: configuredURL.path))
    XCTAssertFalse(
        FileManager.default.fileExists(atPath: defaultURL.path),
        "an explicit service destination must take precedence over the process fallback")
    let attributes = try FileManager.default.attributesOfItem(atPath: configuredURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
}

func testAgentRunnerDoesNotFollowOrMutateUnsafeWireLogTargets() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    defer { Task { await host.stop() } }

    let directory = home.root.appending(path: "unsafe-wire", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let symlinkURL = directory.appending(path: "symlink.jsonl")
    let victimURL = home.root.appending(path: "symlink-victim.jsonl")
    let victimContents = Data("do not alter symlink target\n".utf8)
    try victimContents.write(to: victimURL)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: victimURL)

    let permissiveURL = directory.appending(path: "permissive.jsonl")
    let permissiveContents = Data("do not append to permissive file\n".utf8)
    try permissiveContents.write(to: permissiveURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o644))],
        ofItemAtPath: permissiveURL.path)

    try await runAgentRunnerRecordingFixture(home: home, host: host, wireLogURL: symlinkURL)
    try await runAgentRunnerRecordingFixture(home: home, host: host, wireLogURL: permissiveURL)

    XCTAssertEqual(try Data(contentsOf: victimURL), victimContents)
    XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path),
        victimURL.path)
    XCTAssertEqual(try Data(contentsOf: permissiveURL), permissiveContents)
    let attributes = try FileManager.default.attributesOfItem(atPath: permissiveURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
}

let casesAgentRunnerWireLog: [Case] = [
    ("agent runner: records payloads at the configured path", {
        try await testAgentRunnerRecordsAtConfiguredWireLogURL()
    }),
    ("agent runner: skips symlink and permissive wire-log targets", {
        try await testAgentRunnerDoesNotFollowOrMutateUnsafeWireLogTargets()
    }),
]
