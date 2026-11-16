import Foundation
@testable import AviaryCore

private func withMuseClient(_ body: (MuseWorkerClient) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aviary-muse-client-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let manifest = MuseWorkerManifest(identity: .allocate(workHostID: "host-test"), cwd: "/tmp",
        model: "muse-spark-1.3", effort: nil, title: "fixture", initialPrompt: "", initialInputID: nil)
    try await body(MuseWorkerClient.reserve(home: home, manifest: manifest))
}

func testMuseWorkerClientLostReceiptKeepsExactAttempt() async throws {
    try await withMuseClient { client in
        let sid = client.manifest.identity.sessionID, instance = client.manifest.instanceID
        let lease = try client.store.acquireOwner(sessionID: sid, instanceID: instance)
        defer { lease.release() }
        var snapshot = MuseWorkerSnapshot(instanceID: instance, sessionID: sid)
        snapshot.state = .idle; snapshot.commandState = .idle
        try client.store.writeSnapshot(sessionID: sid, expectedInstanceID: instance,
            snapshot: MuseWorkerCodec.pack(snapshot))
        let id = MuseMSPSession.newCommandID(), request = MuseWorkerRequest(.send, text: "exact input")
        do { _ = try await client.request(request, commandID: id, timeout: 0.1); XCTFail("expected unconfirmed") }
        catch MuseWorkerClient.Error.deliveryUnknown(let actual) { XCTAssertEqual(actual, id) }
        let saved = try client.store.command(sessionID: sid, expectedInstanceID: instance, commandID: id)
        XCTAssertEqual(saved.stage, .pending)
        _ = try client.store.markDispatched(sessionID: sid, expectedInstanceID: instance, commandID: id)
        let reply = MuseWorkerReply(receipt: .init(admission: .rejected(commandID: id, reason: .emptyInput)))
        _ = try client.store.settleCommand(sessionID: sid, expectedInstanceID: instance,
            commandID: id, receipt: MuseWorkerCodec.pack(reply))
        let replay = try await client.request(request, commandID: id)
        XCTAssertFalse(replay.receipt?.wasAdmitted ?? true)
        XCTAssertEqual(try client.store.command(sessionID: sid, expectedInstanceID: instance, commandID: id).sequence, saved.sequence)
        do { _ = try await client.request(.init(.send, text: "different"), commandID: id); XCTFail("ID reuse accepted") }
        catch MuseWorkerStore.Error.commandContentMismatch { XCTAssertTrue(true) }
    }
}

func testMuseWorkerClientUnresponsiveNeverSubmits() async throws {
    try await withMuseClient { client in
        let sid = client.manifest.identity.sessionID, instance = client.manifest.instanceID
        let lease = try client.store.acquireOwner(sessionID: sid, instanceID: instance)
        defer { lease.release() }
        var snapshot = MuseWorkerSnapshot(instanceID: instance, sessionID: sid)
        snapshot.observedAt = Date(timeIntervalSinceNow: -20)
        try client.store.writeSnapshot(sessionID: sid, expectedInstanceID: instance,
            snapshot: MuseWorkerCodec.pack(snapshot))
        let id = MuseMSPSession.newCommandID()
        do { _ = try await client.request(.init(.send, text: "no effect"), commandID: id); XCTFail("stale worker admitted") }
        catch MuseWorkerClient.Error.unresponsive { XCTAssertTrue(true) }
        do { _ = try client.store.command(sessionID: sid, expectedInstanceID: instance, commandID: id); XCTFail("command was persisted") }
        catch MuseWorkerStore.Error.commandMissing { XCTAssertTrue(true) }
    }
}

let casesMuseWorkerClient: [Case] = [
    ("Muse worker client: lost receipt and exact retry", { try await testMuseWorkerClientLostReceiptKeepsExactAttempt() }),
    ("Muse worker client: stale snapshot no admission", { try await testMuseWorkerClientUnresponsiveNeverSubmits() }),
]
