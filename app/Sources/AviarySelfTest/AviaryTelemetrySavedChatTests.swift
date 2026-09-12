import Foundation
import OpenTelemetrySdk
@testable import AviaryCore

/// Core-only receipt for the saved-chat service path. The signed ChatJourneyProbe remains the
/// executable proof of AppModel's save/relaunch boundaries; this fixture does not impersonate it.
let casesAviaryTelemetrySavedChat: [Case] = [
    ("telemetry saved intent crosses Unix service and canonical delivery", {
        try await testAviaryTelemetrySavedIntentToCanonicalDelivery()
    }),
]

private struct TelemetrySavedChatProvider: ChatProvider {
    let id = "telemetry-saved-chat-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: "telemetry-saved-chat-test"))
            continuation.finish()
        }
    }
}

private func telemetrySavedChatAttribute(
    _ span: SpanData, _ key: String
) -> String? {
    guard case .string(let value)? = span.attributes[key] else { return nil }
    return value
}

private func telemetrySavedChatEventAttribute(
    _ event: SpanData.Event, _ key: String
) -> String? {
    guard case .string(let value)? = event.attributes[key] else { return nil }
    return value
}

private func telemetrySavedChatAssembly() throws -> SystemPromptAssembly {
    let text = "telemetry saved chat system prompt"
    return try SystemPromptAssembly(text: text, sources: [
        try PromptSource(
            sourceID: "telemetry-saved-chat-system", kind: .generated,
            label: "Telemetry saved chat test", fullBody: text,
            deliveredBody: text, renderedBody: text),
    ])
}

private func telemetrySavedChatContains(
    _ needle: String, in spans: [SpanData]
) -> Bool {
    spans.contains { span in
        if span.name.contains(needle) { return true }
        if span.attributes.values.contains(where: { String(describing: $0).contains(needle) }) {
            return true
        }
        return span.events.contains { event in
            event.name.contains(needle)
                || event.attributes.values.contains {
                    String(describing: $0).contains(needle)
                }
        }
    }
}

private func telemetrySavedChatDrainHosted(
    service: JournalBackedWorkService, client: ClientRef
) async {
    guard let page = try? await service.registry.list(limit: 32) else { return }
    for lookup in page.entries {
        guard case .live(let entry) = lookup else { continue }
        var lastCursor: JournalCursor?
        for _ in 0..<200 {
            let snapshot = await entry.hostedWork.snapshot()
            if snapshot.lifecycle == .ended && snapshot.journalHealth == .closed { break }
            if let cursor = snapshot.latestWorkCursor, cursor != lastCursor {
                lastCursor = cursor
                _ = try? await entry.hostedWork.submit(HostedInHouseWorkCommand(
                    work: entry.hostedWork.identity.work,
                    session: SessionRef(entry.hostedWork.identity.sessionID),
                    sessionAttachment: entry.hostedWork.sessionAttachment,
                    client: client, commandID: "telemetry-saved-chat-cleanup-end",
                    causalCursor: cursor, command: .endRun))
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private func testAviaryTelemetrySavedIntentToCanonicalDelivery() async throws {
    guard let runtimeHost = try makeHost(.reference) else {
        XCTFail("saved-chat telemetry requires the reference RuntimeHost")
        return
    }
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
        "ast-\(UUID().uuidString.lowercased())", isDirectory: true)
    let homeRoot = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: homeRoot)
    let host = try home.requirePersistedWorkHost()
    let socketPath = root.appendingPathComponent("service.sock").path
    let clientID = ClientRef("telemetry-saved-chat-client")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control, .start, .end]
    let prompt = "private-prompt-\(UUID().uuidString.lowercased())"
    let privatePath = root.appendingPathComponent(
        "private-workspace-\(UUID().uuidString.lowercased())").path
    try FileManager.default.createDirectory(
        atPath: privatePath, withIntermediateDirectories: true)
    let workspaceRegistry = try WorkHostWorkspaceRegistry(home: home)
    let workspace = try workspaceRegistry.registerLocalDirectory(
        URL(fileURLWithPath: privatePath, isDirectory: true),
        label: "Telemetry saved chat", isDefault: true)
    let rawProvider = "private-provider-\(UUID().uuidString.lowercased())"
    let rawModel = "private-model-\(UUID().uuidString.lowercased())"
    let assembly = try telemetrySavedChatAssembly()
    let retainedAssembly = try WorkLaunchManifestStore(home: home).retainPromptAssembly(
        assembly, authority: .workHost(host),
        provenance: WorkLaunchManifestProvenance(source: "telemetry-saved-chat-test"))
    let runtimeAssembly = try retainedAssembly.materialize(using: ContextBodyStore(home: home))

    let pendingStore = try PendingChatStore(home: home)
    let saved = try pendingStore.create(
        prompt: prompt, cwd: privatePath, providerID: rawProvider, modelID: rawModel,
        title: "private-title-\(UUID().uuidString.lowercased())")
    let awaiting = try pendingStore.update(
        saved.changing(phase: .awaitingAcceptance), expectedGeneration: saved.generation)

    let model: ModelSpec = {
        var value = fakeModel()
        // JournalBackedTestManifestStore's retained runtime is intentionally fixed; the Hosted
        // resolver must attest those exact executable facts rather than the request metadata.
        value.providerID = "test-provider"
        value.id = "test-model"
        return value
    }()
    let manifestStore = JournalBackedTestManifestStore(
        productionCapable: true, expectedPrompt: prompt,
        hostedResolver: { binding in
            HostedInHouseWorkConfiguration(
                home: home, cwd: privatePath, model: model,
                provider: TelemetrySavedChatProvider(), runtimeHost: runtimeHost,
                workRunBinding: binding, serviceActorID: "telemetry-saved-chat-service",
                systemPrompt: runtimeAssembly.flattenedText,
                systemPromptAssembly: runtimeAssembly)
        },
        promptAssembly: retainedAssembly, workspaceLocator: privatePath, home: home)
    let service = try JournalBackedWorkService(
        home: home, instanceID: "telemetry-saved-chat-instance",
        startIdentity: "telemetry-saved-chat-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [clientID: capabilities]),
        manifestStore: manifestStore,
        workspaceCatalogProvider: { try workspaceRegistry.catalog() })
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: socketPath), service: service)
    try await server.start()
    let firstClient = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: socketPath), client: clientID)
    let secondClient = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: socketPath), client: clientID)

    do {
        let (result, spans) = try await AviaryTelemetry.withRecording {
            let firstHandshake = try await firstClient.connect(build: "telemetry-saved-chat")
            let createRequest = WorkServiceCreateWorkRequest(
                client: clientID,
                commandID: awaiting.attemptCommandID.uuidString.lowercased(),
                causalControlCursor: firstHandshake.controlCursor,
                configuration: WorkServiceWorkConfiguration(
                    providerID: rawProvider, modelID: rawModel,
                    workspaceID: workspace.workspaceID),
                requestedCapabilities: capabilities)
            let startSeed = try ServiceBackedCreateIntentStore.InitialStart(
                commandID: awaiting.startCommandID, prompt: prompt)
            let createStore = try ServiceBackedCreateIntentStore(home: home, client: clientID)
            try createStore.retain(createRequest, initialStart: startSeed)

            // The response is deliberately discarded while the exact local intent remains. This
            // models the post-commit response-loss boundary without claiming an OS packet fault.
            _ = try await AviaryTelemetry.withSpan(
                "aviary.test.saved_chat.startup",
                attributes: [
                    "aviary.chat.id": .string(AviaryTelemetry.identity(awaiting.id.uuidString)),
                    "aviary.create.command.id": .string(
                        AviaryTelemetry.identity(createRequest.commandID)),
                    "aviary.start.command.id": .string(
                        AviaryTelemetry.identity(awaiting.startCommandID)),
                ], root: true) {
                    try await firstClient.createWork(createRequest)
                }
            await firstClient.close()

            _ = try await secondClient.connect(build: "telemetry-saved-chat-relaunch")
            return try await AviaryTelemetry.withSpan(
                "aviary.test.saved_chat.startup",
                attributes: [
                    "aviary.chat.id": .string(AviaryTelemetry.identity(awaiting.id.uuidString)),
                    "aviary.create.command.id": .string(
                        AviaryTelemetry.identity(createRequest.commandID)),
                    "aviary.start.command.id": .string(
                        AviaryTelemetry.identity(awaiting.startCommandID)),
                ], root: true) {
                    let replayed = try await AviaryTelemetry.withSpan(
                        "aviary.test.saved_chat.reconcile",
                        attributes: [
                            "aviary.create.command.id": .string(
                                AviaryTelemetry.identity(createRequest.commandID)),
                        ], root: true) {
                            try await secondClient.createWork(createRequest)
                        }
                    XCTAssertEqual(replayed.receipt.state, .duplicate)
                    XCTAssertEqual(try createStore.loadPending().count, 1)

                    let association = try XCTUnwrap(ServiceAttachmentKey(
                        work: replayed.work.work, attachment: replayed.attachment))
                    let associated = try pendingStore.update(
                        awaiting.changing(createdAssociation: association),
                        expectedGeneration: awaiting.generation)
                    let intentStore = try WorkServiceAttachedWorkIntentStore(
                        home: home, key: association)
                    let controller = try WorkServiceAttachedWorkController(
                        service: secondClient, seed: .created(replayed), intentStore: intentStore)
                    _ = try await controller.refresh()
                    let receipt = try await controller.start(
                        prompt, commandID: associated.startCommandID)
                    XCTAssertEqual(receipt.state, .accepted)

                    // The provider intentionally completes immediately. Let Hosted finish that
                    // turn before asking the attached controller for a new paired projection;
                    // refreshing while the Work descriptor and journal are both advancing only
                    // tests a transient read race, not the saved-intent delivery contract.
                    var hostedIdle = false
                    let idleDeadline = Date().addingTimeInterval(15)
                    while Date() < idleDeadline && !hostedIdle {
                        if let lookup = await service.registry.lookup(replayed.work.work),
                           case .live(let entry) = lookup {
                            let snapshot = await entry.hostedWork.snapshot()
                            hostedIdle = snapshot.lifecycle == .idle
                                && snapshot.journalHealth == .healthy
                                && snapshot.runtimeTransportConnected
                        }
                        if !hostedIdle { try await Task.sleep(nanoseconds: 25_000_000) }
                    }
                    XCTAssertTrue(hostedIdle, "Start must settle in the owned Hosted run")
                    let projection = try await controller.refresh()
                    XCTAssertEqual(projection.descriptor.execution, .idle)
                    XCTAssertEqual(projection.workSnapshot.execution, .idle)
                    XCTAssertEqual(projection.descriptor.currentRun, projection.workSnapshot.activeRun)
                    XCTAssertTrue(
                        associated.hasCanonicalDelivery(in: projection),
                        "accepted Start must reach exact canonical input delivery")
                    let ledgerID = WorkServiceCommandLedgerIdentity.commandID(
                        client: association.client, commandID: associated.startCommandID)
                    let command = try XCTUnwrap(projection.workSnapshot.commands[ledgerID])
                    let deliveryEvent = try XCTUnwrap(command.deliveryEventRef)
                    let end = try await controller.end(
                        commandID: "telemetry-saved-chat-end")
                    XCTAssertEqual(end.state, .accepted)
                    var hostedClosed = false
                    let endDeadline = Date().addingTimeInterval(15)
                    while Date() < endDeadline && !hostedClosed {
                        if let lookup = await service.registry.lookup(replayed.work.work),
                           case .live(let entry) = lookup {
                            let snapshot = await entry.hostedWork.snapshot()
                            hostedClosed = snapshot.lifecycle == .ended
                                && snapshot.journalHealth == .closed
                        }
                        if !hostedClosed { try await Task.sleep(nanoseconds: 25_000_000) }
                    }
                    XCTAssertTrue(hostedClosed, "End must close the fixture's Hosted journals")
                    return (projection, deliveryEvent)
                }
        }

        let startupRoots = spans.filter {
            $0.name == "aviary.test.saved_chat.startup" && $0.parentSpanId == nil
        }
        XCTAssertEqual(startupRoots.count, 2)
        XCTAssertNotEqual(startupRoots[0].traceId.hexString, startupRoots[1].traceId.hexString)
        XCTAssertEqual(
            telemetrySavedChatAttribute(startupRoots[0], "aviary.create.command.id"),
            telemetrySavedChatAttribute(startupRoots[1], "aviary.create.command.id"))

        let canonical = try XCTUnwrap(spans.first {
            $0.name == "aviary.command.canonical_delivery"
                && telemetrySavedChatAttribute($0, "aviary.outcome") == "succeeded"
        })
        XCTAssertEqual(canonical.traceId.hexString, startupRoots[1].traceId.hexString)
        let canonicalEvent = try XCTUnwrap(canonical.events.first {
            $0.name == "aviary.command.canonical_delivery"
        })
        XCTAssertEqual(
            telemetrySavedChatEventAttribute(canonicalEvent, "aviary.event.id"),
            AviaryTelemetry.identity(result.1.eventID))
        XCTAssertTrue(spans.contains {
            $0.kind == .client && telemetrySavedChatAttribute($0, "rpc.method") == "command"
                && $0.traceId.hexString == canonical.traceId.hexString
        })
        XCTAssertTrue(spans.contains {
            $0.kind == .server && telemetrySavedChatAttribute($0, "rpc.method") == "command"
                && $0.traceId.hexString == canonical.traceId.hexString
        })
        for secret in [prompt, privatePath, rawProvider, rawModel, try XCTUnwrap(awaiting.title)] {
            XCTAssertFalse(telemetrySavedChatContains(secret, in: spans))
        }
    } catch {
        await telemetrySavedChatDrainHosted(service: service, client: clientID)
        await firstClient.close()
        await secondClient.close()
        await server.stop()
        await service.controlJournal.close()
        throw error
    }
    await firstClient.close()
    await secondClient.close()
    await server.stop()
    await service.controlJournal.close()
}
