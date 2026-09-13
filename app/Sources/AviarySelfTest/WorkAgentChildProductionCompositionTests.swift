import Foundation
@testable import AviaryCore

private struct ProductionCompositionProvider: ChatProvider {
    let id = "production-composition-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private func productionCompositionHome() throws -> AgentHome {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appending(
            path: "avpc-\(UUID().uuidString.lowercased().prefix(12))",
            directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return AgentHome(root: root)
}

private func productionCompositionBinding(
    home: AgentHome, suffix: String
) throws -> WorkRunBinding {
    let host = try home.requirePersistedWorkHost()
    return WorkRunBinding(
        workBinding: WorkBinding(
            session: SessionRef("production-child-session-\(suffix)"),
            work: WorkRef(
                workHostID: host.workHostID,
                workID: "production-child-work-\(suffix)"),
            workHost: host,
            sessionAttachment: SessionAttachmentRef(
                "production-child-attachment-\(suffix)")),
        run: RunRef("production-child-run-\(suffix)"))
}

private func productionCompositionManifest(
    binding: WorkRunBinding, runtimeVariant: String = "python3"
) -> WorkLaunchManifest {
    WorkLaunchManifest(
        identity: WorkLaunchManifestIdentity(
            work: binding.workBinding.work,
            session: binding.workBinding.session,
            sessionAttachment: binding.workBinding.sessionAttachment,
            run: binding.run),
        startIntent: WorkLaunchStartIntent(
            client: ClientRef("production-child-client"),
            commandID: "production-child-start",
            causalWorkCursor: JournalCursor(
                journal: .work(binding.workBinding.work), eventID: nil, sequence: 0),
            bodyDigest: "sha256:" + String(repeating: "0", count: 64)),
        workspace: WorkLaunchWorkspace(locator: "/tmp", policy: .temporary),
        runtime: WorkLaunchRuntime(
            providerID: "fake", modelID: "test-model", runtimeVariant: runtimeVariant),
        provenance: WorkLaunchManifestProvenance(source: "production-child-test"))
}

private func productionCompositionConfiguration(
    home: AgentHome, binding: WorkRunBinding
) -> HostedInHouseWorkConfiguration {
    HostedInHouseWorkConfiguration(
        home: home,
        cwd: "/tmp",
        model: ModelSpec(rpc: .object([
            "id": .string("test-model"), "provider": .string("fake"),
            "contextWindow": .number(100_000),
        ])),
        provider: ProductionCompositionProvider(),
        runtimeHost: RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", "parent.py"]),
        workRunBinding: binding,
        serviceActorID: "production-child-owner",
        systemPrompt: "Production child composition test",
        maxIterations: 2)
}

func testWorkAgentChildProductionHostedResolverUsesOneOwnerAndFreshRuntimes() async throws {
    let home = try productionCompositionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let binding = try productionCompositionBinding(home: home, suffix: "owner")
    let manifest = productionCompositionManifest(binding: binding)
    let coordinator = try WorkAgentChildCoordinator()
    let wrapped = WorkHostDaemonServiceResolver.agentChildHostedResolver(
        hostedResolver: { _, suppliedBinding, _ in
            productionCompositionConfiguration(home: home, binding: suppliedBinding)
        },
        runtimeHostResolver: { _ in
            {
                RuntimeHost(
                    executable: "/usr/bin/env", arguments: ["python3", "child.py"],
                    parentLifetimeLease: true)
            }
        },
        coordinator: coordinator)

    let policy = WorkLaunchExecutionPolicy(
        projection: .fresh, modelContext: .launchFresh)
    let first = try XCTUnwrap(try await wrapped(manifest, binding, policy))
    let second = try XCTUnwrap(try await wrapped(manifest, binding, policy))
    let firstPilot = try XCTUnwrap(first.agentChildPilot)
    let secondPilot = try XCTUnwrap(second.agentChildPilot)
    XCTAssertTrue(firstPilot.coordinator === coordinator)
    XCTAssertTrue(secondPilot.coordinator === coordinator)
    XCTAssertNil(firstPilot.deadline)
    XCTAssertNil(secondPilot.deadline)

    let firstRuntime = firstPilot.makeRuntimeHost()
    let secondRuntime = secondPilot.makeRuntimeHost()
    XCTAssertTrue(firstRuntime !== secondRuntime)
    XCTAssertTrue(await firstRuntime.claimChildExecutionOwnership())
    XCTAssertTrue(await secondRuntime.claimChildExecutionOwnership())
}

func testWorkAgentChildProductionDurableResolverInstallsShutdownOwnerOnlyWhenEnabled() async throws {
    let home = try productionCompositionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let host = try home.requirePersistedWorkHost()
    let instance = WorkHostInstanceRef(
        host: host, instanceID: "production-child-instance",
        startIdentity: "production-child-start")
    let draft: DurableJournalBackedWorkLaunchManifestStore.DraftResolver = { _ in
        throw WorkServiceProtocolError.sourceIncomplete
    }
    let hosted: DurableJournalBackedWorkLaunchManifestStore.HostedConfigurationResolver = {
        _, _, _ in nil
    }

    let enabled = WorkHostDaemonServiceResolver.durable(
        authorizer: WorkServiceCapabilityPolicy(),
        draftResolver: draft,
        hostedResolver: hosted,
        agentChildRuntimeHostResolver: { _ in
            { RuntimeHost(
                executable: "/usr/bin/env", arguments: ["python3", "child.py"],
                parentLifetimeLease: true) }
        })
    let enabledComposition = try await enabled.open(
        home: home, host: host, instance: instance, environment: [:])
    let enabledLease = try await enabledComposition.freezeChildAdmission()
    XCTAssertNotNil(enabledLease)
    if let enabledLease { await enabledLease.reopen() }
    if let service = enabledComposition.service as? JournalBackedWorkService {
        await service.controlJournal.close()
    }

    let disabled = WorkHostDaemonServiceResolver.durable(
        authorizer: WorkServiceCapabilityPolicy(), draftResolver: draft,
        hostedResolver: hosted)
    let disabledComposition = try await disabled.open(
        home: home, host: host,
        instance: WorkHostInstanceRef(
            host: host, instanceID: "production-child-disabled-instance",
            startIdentity: "production-child-disabled-start"),
        environment: [:])
    XCTAssertNil(try await disabledComposition.freezeChildAdmission())
    if let service = disabledComposition.service as? JournalBackedWorkService {
        await service.controlJournal.close()
    }
}

func testWorkAgentChildProductionDurableResolverRejectsFactoryWithoutHostedMaterial() async throws {
    let home = try productionCompositionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let host = try home.requirePersistedWorkHost()
    let resolver = WorkHostDaemonServiceResolver.durable(
        authorizer: WorkServiceCapabilityPolicy(),
        draftResolver: { _ in throw WorkServiceProtocolError.sourceIncomplete },
        agentChildRuntimeHostResolver: { _ in
            { RuntimeHost(
                executable: "/usr/bin/env", arguments: ["python3", "child.py"],
                parentLifetimeLease: true) }
        })
    do {
        _ = try await resolver.open(
            home: home, host: host,
            instance: WorkHostInstanceRef(
                host: host, instanceID: "production-child-invalid-instance",
                startIdentity: "production-child-invalid-start"),
            environment: [:])
        XCTFail("a child runtime factory without Hosted material must fail closed")
    } catch WorkServiceProtocolError.sourceIncomplete {
    }
}

func testWorkAgentChildProductionOwnershipAttestationIsBidirectional() async throws {
    let home = try productionCompositionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let binding = try productionCompositionBinding(home: home, suffix: "attestation")
    let service = try JournalBackedWorkService(
        home: home, authorizer: WorkServiceCapabilityPolicy())
    var configuration = productionCompositionConfiguration(home: home, binding: binding)
    XCTAssertTrue(await service.attestsAgentChildOwnership(configuration))

    let owner = try WorkAgentChildCoordinator()
    configuration.agentChildPilot = WorkAgentChildPilot(
        coordinator: owner,
        makeRuntimeHost: {
            RuntimeHost(
                executable: "/usr/bin/env", arguments: ["python3", "child.py"],
                parentLifetimeLease: true)
        })
    XCTAssertFalse(await service.attestsAgentChildOwnership(configuration))

    try await service.installAgentHandleCanceller(owner)
    XCTAssertTrue(await service.attestsAgentChildOwnership(configuration))
    var missingPilot = configuration
    missingPilot.agentChildPilot = nil
    XCTAssertFalse(await service.attestsAgentChildOwnership(missingPilot))
    let foreign = try WorkAgentChildCoordinator()
    var foreignPilot = configuration
    foreignPilot.agentChildPilot = WorkAgentChildPilot(
        coordinator: foreign,
        makeRuntimeHost: configuration.agentChildPilot!.makeRuntimeHost)
    XCTAssertFalse(await service.attestsAgentChildOwnership(foreignPilot))
    await service.controlJournal.close()
}

func testLocalWorkHostChildRuntimeResolverPinsVariantAndReturnsFreshOwnership() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-production-child-runtime-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    let runtime = root.appending(path: "runtime", directoryHint: .isDirectory)
    let scriptDirectory = runtime.appending(
        path: "runtime-hosts/python3", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: scriptDirectory, withIntermediateDirectories: true)
    try "#!/usr/bin/env python3\n".write(
        to: scriptDirectory.appending(path: "host.py"),
        atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = try WorkHostWorkspaceRegistry(home: home)
    let resolver = LocalWorkHostLaunchResolver(configuration: .init(
        home: home,
        workspaceRegistry: registry,
        runtimeRepositoryRoot: runtime,
        models: ModelsConfig(
            providers: [], raw: .object([:]), fileURL: home.modelsFile, exists: true),
        auth: AuthInfo(), environment: [:], preferences: ModelPreferences()))
    let binding = try productionCompositionBinding(home: home, suffix: "runtime")
    let factory = try await resolver.agentChildRuntimeHostResolver(
        productionCompositionManifest(binding: binding))
    let first = factory()
    let second = factory()
    XCTAssertTrue(first !== second)
    XCTAssertTrue(await first.claimChildExecutionOwnership())
    XCTAssertTrue(await second.claimChildExecutionOwnership())
}

let casesWorkAgentChildProductionComposition: [Case] = [
    ("phase5 production child: one owner and fresh runtimes", {
        try await testWorkAgentChildProductionHostedResolverUsesOneOwnerAndFreshRuntimes()
    }),
    ("phase5 production child: durable activation owns shutdown", {
        try await testWorkAgentChildProductionDurableResolverInstallsShutdownOwnerOnlyWhenEnabled()
    }),
    ("phase5 production child: factory without Hosted fails closed", {
        try await testWorkAgentChildProductionDurableResolverRejectsFactoryWithoutHostedMaterial()
    }),
    ("phase5 production child: owner attestation is bidirectional", {
        try await testWorkAgentChildProductionOwnershipAttestationIsBidirectional()
    }),
    ("phase5 production child: Local runtime factory is fresh", {
        try await testLocalWorkHostChildRuntimeResolverPinsVariantAndReturnsFreshOwnership()
    }),
]
