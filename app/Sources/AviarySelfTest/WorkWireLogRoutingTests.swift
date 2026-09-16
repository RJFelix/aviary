import Foundation
@testable import AviaryCore

private struct WorkWireLogRoutingProvider: ChatProvider {
    let id = "fake"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

func testAgentChildWireLogsUseDistinctRunFilesInCapturedDirectory() {
    let directory = URL(fileURLWithPath: "/tmp/captured-wire-logs", isDirectory: true)
    let parentURL = directory.appendingPathComponent("run-parent-run.jsonl")
    let first = AgentChildWireLogLocation.url(forRunID: "child-one-run", in: directory)
    let second = AgentChildWireLogLocation.url(forRunID: "child-two-run", in: directory)

    XCTAssertEqual(first?.deletingLastPathComponent(), directory)
    XCTAssertEqual(second?.deletingLastPathComponent(), directory)
    XCTAssertEqual(first?.lastPathComponent, "run-child-one-run.jsonl")
    XCTAssertEqual(second?.lastPathComponent, "run-child-two-run.jsonl")
    XCTAssertNotEqual(first, second)
    XCTAssertNotEqual(first, parentURL)
    XCTAssertNil(AgentChildWireLogLocation.url(forRunID: "child-run", in: nil))
}

func testFactoryRejectsMissingMismatchedAndNonFileWireLogDestinations() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity.allocate(
        workHostID: hostID, sessionID: "wire-log-validation-session",
        workID: "wire-log-validation-work", runID: "wire-log-validation-run")
    let binding = WorkBinding(
        session: SessionRef(identity.sessionID), work: identity.work,
        workHost: WorkHostRef(hostID),
        sessionAttachment: SessionAttachmentRef("wire-log-validation-attachment"))
    let workRunBinding = WorkRunBinding(
        workBinding: binding, run: RunRef(identity.runID))
    let runtimeHost = RuntimeHost(executable: "/usr/bin/env", arguments: ["python3"])
    let invalidDestinations: [(Bool, URL?)] = [
        (true, nil),
        (false, URL(fileURLWithPath: "/tmp/unused-wire.jsonl")),
        (true, URL(string: "https://example.invalid/wire.jsonl")),
        (true, URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 4096))),
    ]

    for (recordPayloads, wireLogURL) in invalidDestinations {
        let configuration = InHouseWorkFactory.Configuration(
            home: home, cwd: "/tmp", model: fakeModel(),
            provider: WorkWireLogRoutingProvider(), runtimeHost: runtimeHost,
            workRunBinding: workRunBinding, serviceActorID: "wire-log-validation-host",
            systemPrompt: "wire-log validation", recordPayloads: recordPayloads,
            wireLogURL: wireLogURL)
        do {
            _ = try await InHouseWorkFactory.open(configuration: configuration)
            XCTFail("factory accepted an invalid wire-log destination")
        } catch let error as HostedInHouseWorkError {
            guard case .invalidConfiguration(let detail) = error else {
                XCTFail("unexpected factory rejection: \(error)")
                continue
            }
            XCTAssertTrue(detail.contains("wire-log"), detail)
        }
    }
}

let casesWorkWireLogRouting: [Case] = [
    ("child wire logs: use distinct run files in the captured directory", {
        testAgentChildWireLogsUseDistinctRunFilesInCapturedDirectory()
    }),
    ("work factory: reject missing, mismatched, or non-file wire-log destinations", {
        try await testFactoryRejectsMissingMismatchedAndNonFileWireLogDestinations()
    }),
]
