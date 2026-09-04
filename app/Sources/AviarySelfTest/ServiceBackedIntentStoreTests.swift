import Foundation
@testable import AviaryCore

private func serviceBackedIntentFixture()
    async throws -> (AgentHome, URL, InMemoryWorkService, WorkServiceCreateWorkResponse,
                     ServiceBackedCreateIntentStore.InitialStart) {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-service-intents-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    let host = WorkHostRef("intent-host")
    let client = ClientRef("intent-client")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control, .start, .send]
    let service = InMemoryWorkService(
        host: host,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: capabilities]))
    let handshake = try await service.handshake(WorkServiceHandshakeRequest(client: client))
    let request = WorkServiceCreateWorkRequest(
        client: client, commandID: "intent-create",
        causalControlCursor: handshake.controlCursor,
        requestedCapabilities: capabilities)
    let seed = try ServiceBackedCreateIntentStore.InitialStart(
        commandID: "intent-start", prompt: "survive the GUI")
    let createStore: ServiceBackedCreateIntentStore
    do {
        createStore = try ServiceBackedCreateIntentStore(home: home, client: client)
    } catch {
        throw UnwrapFailure(description: "Create intent store initialization failed: \(error)")
    }
    do {
        try createStore.retain(request, initialStart: seed)
    } catch {
        throw UnwrapFailure(description: "Create intent retention failed: \(error)")
    }
    let response: WorkServiceCreateWorkResponse
    do {
        response = try await service.createWork(request)
    } catch {
        throw UnwrapFailure(description: "reference Create failed: \(error)")
    }
    return (home, root, service, response, seed)
}

func testServiceBackedIntentStoresCarryCreateIntoCanonicalStartEvidence() async throws {
    let (home, root, service, response, seed) = try await serviceBackedIntentFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = response.attachment.client
    let createStore = try ServiceBackedCreateIntentStore(home: home, client: client)
    let retainedCreate = try XCTUnwrap(createStore.loadPending().first)
    XCTAssertEqual(retainedCreate.initialStart, seed)

    let startIntent = try ServiceBackedStartIntent(
        seed: seed, response: response, client: client)
    let startStore = try ServiceBackedStartIntentStore(
        home: home, client: client, work: response.work.work)
    try startStore.retain(startIntent)
    try createStore.clear(retainedCreate.request)
    XCTAssertTrue(try createStore.loadPending().isEmpty)
    XCTAssertEqual(try startStore.load(), startIntent)
    XCTAssertEqual(startIntent.causalWorkCursor, response.workCursor)

    let controller: WorkServiceAttachedWorkController
    do {
        controller = try WorkServiceAttachedWorkController(
            service: service, seed: .created(response),
            intentStore: WorkServiceAttachedWorkIntentStore(
                home: home, client: client, work: response.work.work))
    } catch {
        throw UnwrapFailure(description: "attached controller construction failed: \(error)")
    }
    do {
        XCTAssertTrue(try await controller.refresh().isCanonical)
    } catch {
        throw UnwrapFailure(description: "initial attached refresh failed: \(error)")
    }
    let receipt: WorkServiceCommandReceipt
    do {
        receipt = try await controller.start(seed.prompt, commandID: seed.commandID)
    } catch {
        throw UnwrapFailure(description: "Start submission failed: \(error)")
    }
    XCTAssertEqual(receipt.state, .accepted)
    XCTAssertEqual((await controller.pendingCommand())?.state, .awaitingCanonicalEvidence)
    // The independent bootstrap marker remains until a complete Work read proves the exact
    // client-qualified CommandRef at the Create response's causal cursor.
    XCTAssertEqual(try startStore.load(), startIntent)
    let projection: WorkServiceAttachedWorkProjection
    do {
        projection = try await controller.refresh()
    } catch {
        throw UnwrapFailure(description: "canonical Start refresh failed: \(error)")
    }
    XCTAssertTrue(startIntent.hasCanonicalEvidence(in: projection))
    XCTAssertNil(await controller.pendingCommand())
    try startStore.clear(startIntent)
    XCTAssertNil(try startStore.load())
}

func testServiceBackedIntentStoresRejectConflictsForeignBindingsAndCorruption() async throws {
    let (home, root, _, response, seed) = try await serviceBackedIntentFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = response.attachment.client
    let createStore = try ServiceBackedCreateIntentStore(home: home, client: client)
    let retained = try XCTUnwrap(createStore.loadPending().first)
    do {
        try createStore.retain(
            retained.request,
            initialStart: ServiceBackedCreateIntentStore.InitialStart(
                commandID: seed.commandID, prompt: "different bytes"))
        XCTFail("the same Create identity cannot change its Start seed")
    } catch LocalCreateIntentError.conflict {
        XCTAssertTrue(true)
    }
    do {
        _ = try ServiceBackedStartIntent(
            seed: seed, response: response, client: ClientRef("foreign-client"))
        XCTFail("a foreign client cannot consume a host-minted Create response")
    } catch ServiceBackedStartIntentError.invalid {
        XCTAssertTrue(true)
    }

    let intent = try ServiceBackedStartIntent(seed: seed, response: response, client: client)
    let store = try ServiceBackedStartIntentStore(
        home: home, client: client, work: response.work.work)
    try store.retain(intent)
    try Data("{\"schemaVersion\":3".utf8).write(to: store.url, options: .atomic)
    do {
        _ = try store.load()
        XCTFail("a torn Start intent must fail closed")
    } catch ServiceBackedStartIntentError.corrupt {
        XCTAssertTrue(true)
    }
}

func testServiceBackedStartIntentClearFailurePreservesRecoveryMarker() async throws {
    let (home, root, _, response, seed) = try await serviceBackedIntentFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = response.attachment.client
    let intent = try ServiceBackedStartIntent(seed: seed, response: response, client: client)
    let store = try ServiceBackedStartIntentStore(
        home: home, client: client, work: response.work.work)
    try store.retain(intent)
    let directory = store.url.deletingLastPathComponent()
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o000))], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: directory.path)
    }
    do {
        try store.clear(intent)
        XCTFail("an unwritable intent directory must not report successful cleanup")
    } catch {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: directory.path)
        XCTAssertEqual(try store.load(), intent)
    }
}

func testServiceBackedIntentStoresRejectSymlinksModesAndOversizeRecords() async throws {
    let (home, root, _, response, seed) = try await serviceBackedIntentFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = response.attachment.client
    let createStore = try ServiceBackedCreateIntentStore(home: home, client: client)
    let createRequest = try XCTUnwrap(try createStore.loadPending().first?.request)
    let createDirectory = createStore.directory
    let movedCreateDirectory = root.appending(path: "moved-create-intents", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: createDirectory, to: movedCreateDirectory)
    try FileManager.default.createSymbolicLink(
        at: createDirectory, withDestinationURL: movedCreateDirectory)
    do {
        _ = try createStore.loadPending()
        XCTFail("Create intent directories must not be symlinks")
    } catch LocalCreateIntentError.corrupt {
        XCTAssertTrue(true)
    }
    try FileManager.default.removeItem(at: createDirectory)
    try FileManager.default.moveItem(at: movedCreateDirectory, to: createDirectory)
    let createURL = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
        at: createStore.directory, includingPropertiesForKeys: nil).first(where: {
            $0.pathExtension == "json"
        }))
    let outside = root.appending(path: "outside.json", directoryHint: .notDirectory)
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.removeItem(at: createURL)
    try FileManager.default.createSymbolicLink(at: createURL, withDestinationURL: outside)
    do {
        _ = try createStore.loadPending()
        XCTFail("Create intent symlinks must not be followed")
    } catch LocalCreateIntentError.corrupt {
        XCTAssertTrue(true)
    }
    try FileManager.default.removeItem(at: createURL)
    try createStore.retain(createRequest, initialStart: seed)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o640))], ofItemAtPath: createURL.path)
    do {
        _ = try createStore.loadPending()
        XCTFail("Create intents with group-readable modes must fail closed")
    } catch LocalCreateIntentError.corrupt {
        XCTAssertTrue(true)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: createURL.path)
    try Data(repeating: 0x7f, count: ServiceBackedCreateIntentStore.maximumRecordBytes + 1)
        .write(to: createURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: createURL.path)
    do {
        _ = try createStore.loadPending()
        XCTFail("Oversize Create intents must fail closed")
    } catch LocalCreateIntentError.corrupt {
        XCTAssertTrue(true)
    }

    let startIntent = try ServiceBackedStartIntent(seed: seed, response: response, client: client)
    let startStore = try ServiceBackedStartIntentStore(
        home: home, client: client, work: response.work.work)
    try startStore.retain(startIntent)
    let startDirectory = startStore.url.deletingLastPathComponent()
    let movedStartDirectory = root.appending(path: "moved-start-intents", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: startDirectory, to: movedStartDirectory)
    try FileManager.default.createSymbolicLink(
        at: startDirectory, withDestinationURL: movedStartDirectory)
    do {
        _ = try startStore.load()
        XCTFail("Start intent directories must not be symlinks")
    } catch ServiceBackedStartIntentError.corrupt {
        XCTAssertTrue(true)
    }
    try FileManager.default.removeItem(at: startDirectory)
    try FileManager.default.moveItem(at: movedStartDirectory, to: startDirectory)
    let startOutside = root.appending(path: "outside-start.json", directoryHint: .notDirectory)
    try Data("outside".utf8).write(to: startOutside)
    try FileManager.default.removeItem(at: startStore.url)
    try FileManager.default.createSymbolicLink(at: startStore.url, withDestinationURL: startOutside)
    do {
        _ = try startStore.load()
        XCTFail("Start intent symlinks must not be followed")
    } catch ServiceBackedStartIntentError.corrupt {
        XCTAssertTrue(true)
    }
    try FileManager.default.removeItem(at: startStore.url)
    try startStore.retain(startIntent)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o640))], ofItemAtPath: startStore.url.path)
    do {
        _ = try startStore.load()
        XCTFail("Start intents with group-readable modes must fail closed")
    } catch ServiceBackedStartIntentError.corrupt {
        XCTAssertTrue(true)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: startStore.url.path)
    try Data(repeating: 0x7f, count: ServiceBackedStartIntentStore.maximumRecordBytes + 1)
        .write(to: startStore.url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: startStore.url.path)
    do {
        _ = try startStore.load()
        XCTFail("Oversize Start intents must fail closed")
    } catch ServiceBackedStartIntentError.corrupt {
        XCTAssertTrue(true)
    }
}

func testServiceBackedIntentStoresConvergeUnderConcurrentIdenticalRetains() async throws {
    let (home, root, _, response, seed) = try await serviceBackedIntentFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = response.attachment.client
    let createStore = try ServiceBackedCreateIntentStore(home: home, client: client)
    let request = try XCTUnwrap(try createStore.loadPending().first?.request)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                let store = try ServiceBackedCreateIntentStore(home: home, client: client)
                try store.retain(request, initialStart: seed)
            }
        }
        try await group.waitForAll()
    }
    XCTAssertEqual(try createStore.loadPending().count, 1)

    let intent = try ServiceBackedStartIntent(seed: seed, response: response, client: client)
    let startStore = try ServiceBackedStartIntentStore(
        home: home, client: client, work: response.work.work)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                let store = try ServiceBackedStartIntentStore(
                    home: home, client: client, work: response.work.work)
                try store.retain(intent)
            }
        }
        try await group.waitForAll()
    }
    XCTAssertEqual(try startStore.load(), intent)
}

let casesServiceBackedIntentStores: [Case] = [
    ("phase3 GUI intents carry Create into canonical Start evidence", {
        try await testServiceBackedIntentStoresCarryCreateIntoCanonicalStartEvidence()
    }),
    ("phase3 GUI intents reject conflicts foreign bindings and corruption", {
        try await testServiceBackedIntentStoresRejectConflictsForeignBindingsAndCorruption()
    }),
    ("phase3 GUI intents preserve marker when clear fails", {
        try await testServiceBackedStartIntentClearFailurePreservesRecoveryMarker()
    }),
    ("phase3 GUI intents reject symlinks modes and oversize records", {
        try await testServiceBackedIntentStoresRejectSymlinksModesAndOversizeRecords()
    }),
    ("phase3 GUI intents converge concurrent identical retains", {
        try await testServiceBackedIntentStoresConvergeUnderConcurrentIdenticalRetains()
    }),
]
