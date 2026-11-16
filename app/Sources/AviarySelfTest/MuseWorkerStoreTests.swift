import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private struct MuseWorkerFixture {
    let root: URL
    let store: MuseWorkerStore
    let sessionID = "session-\(UUID().uuidString.lowercased())"
    let instanceID = UUID().uuidString.lowercased()

    init() {
        root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-muse-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = MuseWorkerStore(homeRoot: root)
    }

    func create(_ manifest: JSONValue = .object(["nativeMuseID": .string("muse-1")])) throws {
        _ = try store.createSession(sessionID: sessionID, manifest: manifest, instanceID: instanceID)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func assertMuseWorkerError(
    _ expected: MuseWorkerStore.Error,
    _ body: () throws -> Void,
    line: Int = #line
) {
    do {
        try body()
        XCTFail("expected Muse worker store failure", line: line)
    } catch let error as MuseWorkerStore.Error {
        XCTAssertEqual(error, expected, line: line)
    } catch {
        XCTFail("unexpected Muse worker store error: \(error)", line: line)
    }
}

func testMuseWorkerStoreManifestSnapshotAndPrivateFiles() throws {
    let fixture = MuseWorkerFixture()
    defer { fixture.cleanup() }
    let manifest: JSONValue = .object(["nativeMuseID": .string("muse-native-42"), "model": .string("spark")])
    try fixture.create(manifest)
    XCTAssertEqual(try fixture.store.sessions(), [fixture.sessionID])
    XCTAssertEqual(try fixture.store.loadManifest(sessionID: fixture.sessionID).manifest, manifest)

    let next: JSONValue = .object(["nativeMuseID": .string("muse-native-42"), "cursor": .number(17)])
    XCTAssertEqual(try fixture.store.updateManifest(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, manifest: next).manifest, next)
    let snapshot: JSONValue = .object(["transcript": .array([.string("one"), .string("two")]),
                                       "usage": .object(["input": .number(9_007_199_254_740_000)])])
    try fixture.store.writeSnapshot(sessionID: fixture.sessionID, expectedInstanceID: fixture.instanceID,
                                    snapshot: snapshot)
    XCTAssertEqual(try fixture.store.loadSnapshot(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID), snapshot)

    let dir = fixture.root.appending(path: "muse-workers/\(fixture.sessionID)", directoryHint: .isDirectory)
    var dirInfo = stat()
    XCTAssertEqual(dir.path.withCString { lstat($0, &dirInfo) }, 0)
    XCTAssertEqual(dirInfo.st_mode & mode_t(0o777), mode_t(0o700))
    var fileInfo = stat()
    let manifestURL = dir.appending(path: "manifest.json")
    XCTAssertEqual(manifestURL.path.withCString { lstat($0, &fileInfo) }, 0)
    XCTAssertEqual(fileInfo.st_mode & mode_t(0o777), mode_t(0o600))

    assertMuseWorkerError(.instanceMismatch) {
        try fixture.store.writeSnapshot(sessionID: fixture.sessionID,
            expectedInstanceID: UUID().uuidString, snapshot: snapshot)
    }
}

func testMuseWorkerStoreCommandReplayTransitionsAndReceipt() throws {
    let fixture = MuseWorkerFixture()
    defer { fixture.cleanup() }
    try fixture.create()
    let commandID = UUID().uuidString.lowercased()
    let request: JSONValue = .object(["kind": .string("send"), "text": .string("hello")])
    let submitted = try fixture.store.submitCommand(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, commandID: commandID, request: request)
    XCTAssertEqual(submitted.stage, .pending)
    XCTAssertEqual(submitted.sequence, 1)
    XCTAssertEqual(try fixture.store.submitCommand(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, commandID: commandID, request: request), submitted)
    assertMuseWorkerError(.commandContentMismatch) {
        _ = try fixture.store.submitCommand(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, commandID: commandID,
            request: .object(["kind": .string("send"), "text": .string("changed")]))
    }
    assertMuseWorkerError(.invalidCommandTransition) {
        _ = try fixture.store.settleCommand(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, commandID: commandID, receipt: .string("too early"))
    }

    let dispatched = try fixture.store.markDispatched(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, commandID: commandID)
    XCTAssertEqual(dispatched.stage, .dispatched)
    assertMuseWorkerError(.invalidCommandTransition) {
        _ = try fixture.store.markDispatched(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, commandID: commandID)
    }
    let receipt: JSONValue = .object(["accepted": .bool(true), "nativeTurn": .string("turn-7")])
    let settled = try fixture.store.settleCommand(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, commandID: commandID, receipt: receipt)
    XCTAssertEqual(settled.stage, .settled)
    XCTAssertEqual(settled.receipt, receipt)
    XCTAssertEqual(try fixture.store.command(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, commandID: commandID), settled)
    XCTAssertTrue(try fixture.store.pendingCommands(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID).isEmpty)
    XCTAssertEqual(try fixture.store.settleCommand(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, commandID: commandID, receipt: receipt), settled)
    assertMuseWorkerError(.commandContentMismatch) {
        _ = try fixture.store.settleCommand(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, commandID: commandID, receipt: .string("different"))
    }
}

func testMuseWorkerStoreOwnerLeaseAndResumeFence() throws {
    let fixture = MuseWorkerFixture()
    defer { fixture.cleanup() }
    try fixture.create()
    let commandID = UUID().uuidString.lowercased()
    let request: JSONValue = .object(["prompt": .string("continue")])
    _ = try fixture.store.submitCommand(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, commandID: commandID, request: request)
    let snapshot: JSONValue = .object(["transcript": .array([.string("saved")])])
    try fixture.store.writeSnapshot(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, snapshot: snapshot)

    let lease = try fixture.store.acquireOwner(sessionID: fixture.sessionID, instanceID: fixture.instanceID)
    XCTAssertTrue(try MuseWorkerStore.isOwned(homeRoot: fixture.root, sessionID: fixture.sessionID))
    assertMuseWorkerError(.ownerAlreadyHeld) {
        _ = try fixture.store.acquireOwner(sessionID: fixture.sessionID, instanceID: fixture.instanceID)
    }
    let nextInstance = UUID().uuidString.lowercased()
    assertMuseWorkerError(.ownerAlreadyHeld) {
        _ = try fixture.store.reserveResume(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, newInstanceID: nextInstance, manifest: .object([:]),
            startCommandID: UUID().uuidString, startRequest: .string("{\"operation\":\"start\"}"))
    }
    XCTAssertEqual(try fixture.store.loadManifest(sessionID: fixture.sessionID).instanceID, fixture.instanceID)

    lease.release()
    XCTAssertFalse(try MuseWorkerStore.isOwned(homeRoot: fixture.root, sessionID: fixture.sessionID))
    let resumedManifest: JSONValue = .object(["nativeMuseID": .string("muse-1"), "resume": .bool(true)])
    let resumeStartID = UUID().uuidString.lowercased()
    let startRequest: JSONValue = .string("{\"operation\":\"start\"}")
    let reservation = try fixture.store.reserveResume(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, newInstanceID: nextInstance,
        manifest: resumedManifest, startCommandID: resumeStartID, startRequest: startRequest)
    XCTAssertEqual(reservation.instanceID, nextInstance)
    XCTAssertNotNil(reservation.resumeReservationToken)
    assertMuseWorkerError(.resumeAlreadyReserved) {
        _ = try fixture.store.reserveResume(sessionID: fixture.sessionID,
            expectedInstanceID: nextInstance, newInstanceID: UUID().uuidString,
            manifest: resumedManifest, startCommandID: UUID().uuidString, startRequest: startRequest)
    }
    XCTAssertNil(try fixture.store.loadSnapshot(sessionID: fixture.sessionID, expectedInstanceID: nextInstance))
    XCTAssertEqual(try fixture.store.pendingCommands(sessionID: fixture.sessionID,
        expectedInstanceID: nextInstance).map(\.commandID), [resumeStartID])
    let resumedLease = try fixture.store.acquireOwner(sessionID: fixture.sessionID, instanceID: nextInstance)
    XCTAssertNil(try fixture.store.loadManifest(sessionID: fixture.sessionID).resumeReservationToken)
    XCTAssertEqual(try fixture.store.command(sessionID: fixture.sessionID,
        expectedInstanceID: nextInstance, commandID: resumeStartID).request, startRequest)
    resumedLease.release()
    assertMuseWorkerError(.commandContentMismatch) {
        _ = try fixture.store.submitCommand(sessionID: fixture.sessionID,
            expectedInstanceID: nextInstance, commandID: commandID, request: request)
    }
    assertMuseWorkerError(.instanceMismatch) {
        _ = try fixture.store.command(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, commandID: commandID)
    }
    let nextCommand = try fixture.store.submitCommand(sessionID: fixture.sessionID,
        expectedInstanceID: nextInstance, commandID: UUID().uuidString,
        request: .object(["prompt": .string("after resume")]))
    XCTAssertEqual(nextCommand.sequence, 3, "sequence numbers continue across worker generations")
}

func testMuseWorkerStorePendingCommandsUseSubmissionOrderAndSweepTemps() throws {
    let fixture = MuseWorkerFixture()
    defer { fixture.cleanup() }
    try fixture.create()
    for prompt in ["first", "second", "third"] {
        _ = try fixture.store.submitCommand(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, commandID: UUID().uuidString,
            request: .object(["prompt": .string(prompt)]))
    }
    let directory = fixture.root.appending(path: "muse-workers/\(fixture.sessionID)", directoryHint: .isDirectory)
    let abandonedTemp = directory.appending(path: ".tmp-\(UUID().uuidString)")
    try Data("incomplete".utf8).write(to: abandonedTemp)
    let commands = try fixture.store.pendingCommands(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID)
    XCTAssertEqual(commands.map(\.sequence), [1, 2, 3])
    XCTAssertEqual(commands.map { $0.request["prompt"]?.stringValue }, ["first", "second", "third"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedTemp.path))
}

func testMuseWorkerStoreDraftHandoffSurvivesEditsAndResolvesAtomically() throws {
    let fixture = MuseWorkerFixture()
    defer { fixture.cleanup() }
    try fixture.create()
    XCTAssertNil(try fixture.store.readDraft(sessionID: fixture.sessionID))
    try fixture.store.writeDraft(sessionID: fixture.sessionID, text: "send this")
    let commandID = UUID().uuidString.lowercased()
    try fixture.store.writeHandoff(sessionID: fixture.sessionID, commandID: commandID,
        instanceID: fixture.instanceID, text: "send this")
    XCTAssertEqual(try fixture.store.readDraftRecord(sessionID: fixture.sessionID)?.handoff?.commandID, commandID)
    assertMuseWorkerError(.commandContentMismatch) {
        try fixture.store.writeHandoff(sessionID: fixture.sessionID, commandID: UUID().uuidString,
            instanceID: fixture.instanceID, text: "another unresolved send")
    }

    // Editing after send starts changes the draft but keeps the in-flight delivery evidence.
    try fixture.store.writeDraft(sessionID: fixture.sessionID, text: "newer edit")
    XCTAssertEqual(try fixture.store.readDraftRecord(sessionID: fixture.sessionID)?.handoff?.text, "send this")
    let unresolved = try fixture.store.resolveHandoff(sessionID: fixture.sessionID,
        expectedCommandID: UUID().uuidString, accepted: true)
    XCTAssertEqual(unresolved?.text, "newer edit")
    XCTAssertEqual(unresolved?.handoff?.commandID, commandID)
    let resolved = try fixture.store.resolveHandoff(sessionID: fixture.sessionID,
        expectedCommandID: commandID, accepted: true)
    XCTAssertEqual(resolved, MuseWorkerStore.Draft(text: "newer edit"))

    let secondID = UUID().uuidString.lowercased()
    try fixture.store.writeHandoff(sessionID: fixture.sessionID, commandID: secondID,
        instanceID: fixture.instanceID, text: "clear when accepted")
    XCTAssertEqual(try fixture.store.resolveHandoff(sessionID: fixture.sessionID,
        expectedCommandID: secondID, accepted: true), MuseWorkerStore.Draft(text: ""))
}

func testMuseWorkerStoreRejectsUnsafeIDsSymlinksAndOversizedPayloads() throws {
    let fixture = MuseWorkerFixture()
    defer { fixture.cleanup() }
    assertMuseWorkerError(.invalidSessionID) {
        _ = try fixture.store.createSession(sessionID: "../escape", manifest: .null,
            instanceID: fixture.instanceID)
    }
    try fixture.create()
    assertMuseWorkerError(.payloadTooLarge) {
        try fixture.store.writeSnapshot(sessionID: fixture.sessionID, expectedInstanceID: fixture.instanceID,
            snapshot: .string(String(repeating: "x", count: MuseWorkerStore.maximumSnapshotBytes)))
    }

    let target = fixture.root.appending(path: "target.json")
    try Data("protected".utf8).write(to: target)
    let manifest = fixture.root.appending(path: "muse-workers/\(fixture.sessionID)/manifest.json")
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: target)
    assertMuseWorkerError(.ioFailure) {
        _ = try fixture.store.loadManifest(sessionID: fixture.sessionID)
    }
    XCTAssertEqual(try Data(contentsOf: target), Data("protected".utf8))
}

func testMuseWorkerStoreCommandCapacityDoesNotEvict() throws {
    let fixture = MuseWorkerFixture()
    defer { fixture.cleanup() }
    try fixture.create()
    let directory = fixture.root.appending(path: "muse-workers/\(fixture.sessionID)", directoryHint: .isDirectory)
    for index in 0..<MuseWorkerStore.maximumRegularCommands {
        let commandID = UUID().uuidString.lowercased()
        let record: JSONValue = .object([
            "commandID": .string(commandID),
            "instanceID": .string(fixture.instanceID),
            "sequence": .number(Double(index + 1)),
            "request": .object(["index": .number(Double(index))]),
            "stage": .string("pending"),
        ])
        let data = try JSONEncoder().encode(record)
        try data.write(to: directory.appending(path: "command-\(commandID).json"), options: .atomic)
    }
    let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("command-") && $0.hasSuffix(".json") }.sorted()
    assertMuseWorkerError(.commandCapacityReached(MuseWorkerStore.maximumRetainedCommands)) {
        _ = try fixture.store.submitCommand(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, commandID: UUID().uuidString,
            request: .object(["new": .bool(true)]))
    }
    let newInstance = UUID().uuidString.lowercased()
    assertMuseWorkerError(.commandCapacityReached(MuseWorkerStore.maximumRetainedCommands)) {
        _ = try fixture.store.reserveResume(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, newInstanceID: newInstance, manifest: .object([:]),
            startCommandID: UUID().uuidString, startRequest: .string("{\"operation\":\"start\"}"))
    }
    XCTAssertEqual(try fixture.store.loadManifest(sessionID: fixture.sessionID).instanceID, fixture.instanceID,
                   "failed resume admission leaves the prior generation intact")
    let endCommand = try fixture.store.submitCommand(sessionID: fixture.sessionID,
        expectedInstanceID: fixture.instanceID, commandID: UUID().uuidString,
        request: .string("{\"operation\":\"end\"}"))
    XCTAssertEqual(endCommand.stage, .pending)
    XCTAssertEqual(endCommand.sequence, MuseWorkerStore.maximumRetainedCommands)
    let after = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("command-") && $0.hasSuffix(".json") }.sorted()
    XCTAssertEqual(after.count, MuseWorkerStore.maximumRetainedCommands)
    XCTAssertTrue(Set(before).isSubset(of: Set(after)), "admission never evicts prior commands")
    assertMuseWorkerError(.commandCapacityReached(MuseWorkerStore.maximumRetainedCommands)) {
        _ = try fixture.store.submitCommand(sessionID: fixture.sessionID,
            expectedInstanceID: fixture.instanceID, commandID: UUID().uuidString,
            request: .string("{\"operation\":\"end\"}"))
    }
}

func testMuseWorkerStoreEnforcesSessionCapacityBeforeCreation() throws {
    let fixture = MuseWorkerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.sessions() // create the store root and serialize fixture setup
    let workers = fixture.root.appending(path: MuseWorkerStore.directoryName, directoryHint: .isDirectory)
    for index in 0..<MuseWorkerStore.maximumSessions {
        try FileManager.default.createDirectory(
            at: workers.appending(path: "session-\(index)", directoryHint: .isDirectory),
            withIntermediateDirectories: false)
    }
    XCTAssertEqual(try fixture.store.sessions().count, MuseWorkerStore.maximumSessions)
    assertMuseWorkerError(.sessionCapacityReached(MuseWorkerStore.maximumSessions)) {
        _ = try fixture.store.createSession(sessionID: fixture.sessionID,
            manifest: .object([:]), instanceID: fixture.instanceID)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: workers.appending(path: fixture.sessionID).path))
}

let casesMuseWorkerStore: [Case] = [
    ("Muse worker: manifest snapshot and private files", { try testMuseWorkerStoreManifestSnapshotAndPrivateFiles() }),
    ("Muse worker: command replay transitions and receipt", { try testMuseWorkerStoreCommandReplayTransitionsAndReceipt() }),
    ("Muse worker: owner lease and resume fence", { try testMuseWorkerStoreOwnerLeaseAndResumeFence() }),
    ("Muse worker: pending commands preserve order and sweep temps", { try testMuseWorkerStorePendingCommandsUseSubmissionOrderAndSweepTemps() }),
    ("Muse worker: draft handoff survives edits and resolves atomically", { try testMuseWorkerStoreDraftHandoffSurvivesEditsAndResolvesAtomically() }),
    ("Muse worker: unsafe ids symlinks and payload limits", { try testMuseWorkerStoreRejectsUnsafeIDsSymlinksAndOversizedPayloads() }),
    ("Muse worker: command capacity does not evict", { try testMuseWorkerStoreCommandCapacityDoesNotEvict() }),
    ("Muse worker: session capacity is checked before creation", { try testMuseWorkerStoreEnforcesSessionCapacityBeforeCreation() }),
]
