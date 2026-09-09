import Foundation
@testable import AviaryCore

private struct LocalResolverFixture {
    let root: URL
    let home: AgentHome
    let workspace: URL
    let workspaceRegistry: WorkHostWorkspaceRegistry
    let workspaceID: WorkHostWorkspaceID
    let runtime: URL
    let resolver: LocalWorkHostLaunchResolver
    let providerID: String
    let modelID: String

    init(modelID: String = "local-model") throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-local-resolver-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        runtime = root.appending(path: "runtime", directoryHint: .isDirectory)
        providerID = "local-provider"
        self.modelID = modelID
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        workspaceRegistry = try WorkHostWorkspaceRegistry(home: home)
        workspaceID = try workspaceRegistry.registerLocalDirectory(
            workspace, label: "Resolver workspace", isDefault: true).workspaceID
        let scriptDirectory = runtime.appending(
            path: "runtime-hosts/python3", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try "#!/usr/bin/env python3\n".write(
            to: scriptDirectory.appending(path: "host.py"), atomically: true, encoding: .utf8)

        var provider = ProviderSpec(
            id: providerID, name: "Local", baseURL: "http://127.0.0.1:1",
            api: "openai-completions", apiKeyExpression: "LOCAL_SECRET",
            authHeader: nil, headers: [:], models: [])
        let providerJSON: JSONValue = .object([
            "api": .string("openai-completions"),
            "baseUrl": .string("http://127.0.0.1:1"),
        ])
        provider.models = [ModelSpec(
            id: modelID, providerID: providerID,
            json: .object(["id": .string(modelID)]), provider: providerJSON)]
        let models = ModelsConfig(
            providers: [provider], raw: .object([:]),
            fileURL: home.modelsFile, exists: true)
        resolver = LocalWorkHostLaunchResolver(configuration: .init(
        home: home,
        workspaceRegistry: workspaceRegistry,
        runtimeRepositoryRoot: runtime,
            models: models,
            auth: AuthInfo(),
            environment: ["LOCAL_SECRET": "do-not-persist-this-secret"],
            preferences: ModelPreferences()))
    }

    func request(
        providerID: String? = nil,
        modelID: String? = nil,
        workspaceID: WorkHostWorkspaceID? = nil,
        includeContextFiles: Bool = true,
        contextPolicy: String? = nil,
        resumePolicy: String? = nil
    ) throws -> WorkServiceCreateWorkRequest {
        let host = try home.requirePersistedWorkHost()
        _ = host
        return WorkServiceCreateWorkRequest(
            client: ClientRef("resolver-test-client"),
            commandID: "resolver-create",
            causalControlCursor: JournalCursor(
                journal: .workHost(host), eventID: nil, sequence: 0),
            configuration: WorkServiceWorkConfiguration(
                providerID: providerID, modelID: modelID,
                contextPolicy: contextPolicy,
                workspaceID: workspaceID ?? self.workspaceID,
                includeContextFiles: includeContextFiles,
                resumePolicy: resumePolicy),
            requestedCapabilities: [.observe, .control])
    }

    func template(
        draft: WorkLaunchManifestDraft? = nil,
        workID: String = "resolver-work"
    ) throws -> (WorkLaunchWorkTemplateRecord, WorkRunBinding) {
        let host = try home.requirePersistedWorkHost()
        let work = WorkRef(workHostID: host.workHostID, workID: workID)
        let binding = WorkBinding(
            session: SessionRef("resolver-session-\(workID)"),
            work: work,
            workHost: host,
            sessionAttachment: SessionAttachmentRef("resolver-attachment-\(workID)"))
        let source: WorkLaunchManifestDraft
        if let draft {
            source = draft
        } else {
            source = try resolver.draft(for: request())
        }
        let key = WorkLaunchCreateKey(
            client: ClientRef("resolver-test-client"),
            requestDigest: try WorkLaunchCreateKey.requestDigest(
                configuration: source.configuration,
                requestedCapabilities: source.requestedCapabilities),
            commandID: "resolver-create",
            causalControlCursor: JournalCursor(
                journal: .workHost(host), eventID: nil, sequence: 0))
        let template = WorkLaunchWorkTemplate(
            work: binding.work, workHost: binding.workHost,
            draft: source, retentionKey: key)
        let bytes = try template.canonicalBytes()
        return (
            WorkLaunchWorkTemplateRecord(
                template: template,
                generation: WorkLaunchWorkTemplateGeneration(
                    generation: 1, digest: try template.contentDigest()),
                templateByteCount: bytes.count),
            WorkRunBinding(workBinding: binding, run: RunRef("resolver-run")))
    }
}

private func localResolverMutateLegacyDevice(home: AgentHome) throws {
    let file = home.workHostWorkspaceRegistryFile
    let data = try Data(contentsOf: file)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var entries = object["entries"] as? [[String: Any]],
          !entries.isEmpty,
          var identity = entries[0]["filesystemIdentity"] as? [String: Any],
          let device = (identity["device"] as? NSNumber)?.uint64Value else {
        throw WorkHostWorkspaceRegistryError.malformedRegistry
    }
    identity.removeValue(forKey: "volumeUUID")
    identity["device"] = NSNumber(value: device &+ 1)
    entries[0]["filesystemIdentity"] = identity
    object["entries"] = entries
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        .write(to: file, options: .atomic)
}

private struct LocalResolverIntegrationFailure: Error, CustomStringConvertible {
    let description: String
}

private func localResolverStage<Value>(
    _ name: String,
    _ operation: () async throws -> Value
) async throws -> Value {
    do {
        return try await operation()
    } catch {
        throw LocalResolverIntegrationFailure(description: "\(name): \(error)")
    }
}

private func localResolverExpectError(
    _ operation: () throws -> Void,
    _ expected: LocalWorkHostLaunchResolver.Error
) {
    do {
        try operation()
        XCTFail("expected \(expected)")
    } catch let error as LocalWorkHostLaunchResolver.Error {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("unexpected error: \(error)")
    }
}

func test_localWorkHostLaunchResolverSelectsDefaultAndQualifiedModels() throws {
    let fixture = try LocalResolverFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let defaultDraft = try fixture.resolver.draft(for: fixture.request())
    let resolvedWorkspace = try fixture.workspaceRegistry.resolve(fixture.workspaceID)
    XCTAssertEqual(defaultDraft.runtime.providerID, fixture.providerID)
    XCTAssertEqual(defaultDraft.runtime.modelID, fixture.modelID)
    XCTAssertEqual(defaultDraft.workspace.locator, resolvedWorkspace.path)
    XCTAssertEqual(defaultDraft.workspace.policy, .workspace)

    let qualified = try fixture.resolver.draft(for: fixture.request(
        providerID: fixture.providerID, modelID: fixture.modelID))
    XCTAssertEqual(qualified.runtime, defaultDraft.runtime)

    localResolverExpectError({
        _ = try fixture.resolver.draft(for: fixture.request(
            providerID: fixture.providerID, modelID: "missing-model"))
    }, .modelUnavailable)
}

func test_localWorkHostLaunchResolverBoundsWorkspaceAndRuntime() throws {
    let fixture = try LocalResolverFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let unknownWorkspaceID = try WorkHostWorkspaceID(
        "workspace-00000000-0000-0000-0000-000000000000")
    localResolverExpectError({
        _ = try fixture.resolver.draft(for: fixture.request(workspaceID: unknownWorkspaceID))
    }, .workspaceUnavailable)

    // The current durable service attests the default prompt/resume policy only.  Reject these
    // request knobs at Create rather than accepting a descriptor that Start cannot reconstruct.
    localResolverExpectError({
        _ = try fixture.resolver.draft(for: fixture.request(includeContextFiles: false))
    }, .invalidConfiguration)
    localResolverExpectError({
        _ = try fixture.resolver.draft(for: fixture.request(contextPolicy: "custom"))
    }, .invalidConfiguration)
    localResolverExpectError({
        _ = try fixture.resolver.draft(for: fixture.request(resumePolicy: "session"))
    }, .invalidConfiguration)

    var runtimeVariants = fixture.resolver.configuration.allowedRuntimeVariants
    runtimeVariants.remove("python3")
    let runtimeResolver = LocalWorkHostLaunchResolver(configuration: .init(
        home: fixture.home,
        workspaceRegistry: fixture.workspaceRegistry,
        runtimeRepositoryRoot: fixture.runtime,
        allowedRuntimeVariants: runtimeVariants,
        models: fixture.resolver.configuration.models,
        auth: fixture.resolver.configuration.auth,
        environment: fixture.resolver.configuration.environment))
    // The current Create API chooses the host's default python3 variant. Removing it therefore
    // fails before body assembly and proves the runtime allowlist is authoritative.
    localResolverExpectError({
        _ = try runtimeResolver.draft(for: fixture.request())
    }, .runtimeVariantNotAllowed)

    // The registry revalidates its private path on every resolution. Replacing the registered
    // directory with a symlink therefore fails closed even though the client retained only the
    // opaque ID.
    let replacement = fixture.root.appending(path: "replacement", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: fixture.workspace)
    try FileManager.default.createSymbolicLink(
        at: fixture.workspace, withDestinationURL: replacement)
    localResolverExpectError({
        _ = try fixture.resolver.draft(for: fixture.request())
    }, .workspaceSymlink)

    // A new directory at the same path is just as invalid as a symlink: the opaque workspace ID
    // remains bound to the original device/inode and cannot be silently rebound on Create.
    try FileManager.default.removeItem(at: fixture.workspace)
    try FileManager.default.createDirectory(
        at: fixture.workspace, withIntermediateDirectories: true)
    localResolverExpectError({
        _ = try fixture.resolver.draft(for: fixture.request())
    }, .workspaceUnavailable)
}

func test_localWorkHostLaunchResolverDraftDoesNotPersistCredentials() throws {
    let fixture = try LocalResolverFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let draft = try fixture.resolver.draft(for: fixture.request())
    let encoded = String(data: try JSONEncoder().encode(draft), encoding: .utf8) ?? ""
    XCTAssertFalse(encoded.contains("do-not-persist-this-secret"))
    XCTAssertFalse(encoded.contains("LOCAL_SECRET"))
    XCTAssertFalse(encoded.contains("apiKey"))
    XCTAssertFalse(FileManager.default.fileExists(
        atPath: ContextBodyStore(home: fixture.home).root.path),
        "Create must not retain a prompt body")
}

func test_localWorkHostLaunchResolverMaterializesExactRunBodies() async throws {
    let fixture = try LocalResolverFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let draft = try fixture.resolver.draft(for: fixture.request())
    let (_, runBinding) = try fixture.template(draft: draft)
    let bodyStore = ContextBodyStore(home: fixture.home)
    let host = try fixture.home.requirePersistedWorkHost()
    try "initial context marker".write(
        to: fixture.workspace.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    let input = Data("exact start input".utf8)
    let inputRef = try bodyStore.retain(input, authority: .workHost(host))
    let intent = WorkLaunchStartIntent(
        client: ClientRef("resolver-test-client"), commandID: "resolver-start",
        causalWorkCursor: JournalCursor(
            journal: .work(runBinding.workBinding.work), eventID: "work-0", sequence: 0),
        bodyDigest: inputRef.digest!)
    let assembly = try fixture.resolver.assemblePrompt(
        for: draft, startBody: input, startIntent: intent)
    let retainedAssembly = try WorkLaunchManifestStore(home: fixture.home).retainPromptAssembly(
        assembly, authority: .workHost(host),
        provenance: WorkLaunchManifestProvenance(source: "start.prompt.v1"))
    let manifest = try draft.bind(
        to: runBinding, startIntent: intent, initialInputBodyReference: inputRef,
        promptAssembly: retainedAssembly)
    _ = try WorkLaunchManifestStore(home: fixture.home).save(manifest)
    try "ambient mutation must not be read".write(
        to: fixture.workspace.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    let configuration = try await fixture.resolver.hostedConfiguration(
        for: manifest, binding: runBinding,
        policy: WorkLaunchExecutionPolicy(
            projection: .fresh, modelContext: .launchFresh))
    let resolved = try XCTUnwrap(configuration)
    XCTAssertEqual(resolved.workRunBinding, runBinding)
    XCTAssertEqual(resolved.systemPrompt, assembly.flattenedText)
    XCTAssertEqual(resolved.systemPromptAssembly?.flattenedDigest, assembly.flattenedDigest)
    XCTAssertTrue(resolved.systemPrompt.contains("initial context marker"))
    XCTAssertFalse(resolved.systemPrompt.contains("ambient mutation"))
    XCTAssertEqual(resolved.cwd, try fixture.workspaceRegistry.resolve(fixture.workspaceID).path)
    XCTAssertEqual(resolved.model.qualifiedID, "\(fixture.providerID)/\(fixture.modelID)")
    XCTAssertEqual(resolved.projectionMode, .fresh)
    XCTAssertEqual(resolved.modelContextMode, .launchFresh)

    // Start/effect admission performs the same stable identity check. Replacing the registered
    // directory after the manifest was retained cannot make an old Run execute in the new path.
    try FileManager.default.removeItem(at: fixture.workspace)
    try FileManager.default.createDirectory(
        at: fixture.workspace, withIntermediateDirectories: true)
    do {
        _ = try await fixture.resolver.hostedConfiguration(
            for: manifest, binding: runBinding,
            policy: WorkLaunchExecutionPolicy(
                projection: .fresh, modelContext: .launchFresh))
        XCTFail("Start must reject a replaced workspace identity")
    } catch let error as LocalWorkHostLaunchResolver.Error {
        XCTAssertEqual(error, .workspaceUnavailable)
    } catch {
        XCTFail("unexpected replaced-workspace error: \(error)")
    }
}

func test_localWorkHostLaunchResolverProbeIsBoundedAndFailsClosed() throws {
    let fixture = try LocalResolverFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (template, _) = try fixture.template()
    XCTAssertTrue(fixture.resolver.canReconstruct(template))

    // Prompt bytes are Start material, not a prerequisite for the Run-free recovery probe.
    let missingWorkspaceDraft = WorkLaunchManifestDraft(
        workspace: WorkLaunchWorkspace(
            locator: fixture.root.appending(path: "removed-workspace").path,
            policy: template.template.draft.workspace.policy),
        runtime: template.template.draft.runtime,
        configuration: template.template.draft.configuration,
        requestedCapabilities: template.template.draft.requestedCapabilities,
        contextPolicy: template.template.draft.contextPolicy,
        recordingPolicy: template.template.draft.recordingPolicy,
        resumePolicy: template.template.draft.resumePolicy,
        reasoningPolicy: template.template.draft.reasoningPolicy,
        budgetPolicy: template.template.draft.budgetPolicy,
        goal: template.template.draft.goal,
        hooks: template.template.draft.hooks,
        peerScheduler: template.template.draft.peerScheduler,
        provenance: template.template.draft.provenance)
    let (missingWorkspace, _) = try fixture.template(
        draft: missingWorkspaceDraft, workID: "missing-workspace")
    XCTAssertFalse(fixture.resolver.canReconstruct(missingWorkspace))

    let changedProvider = ProviderSpec(
        id: fixture.providerID, name: "Changed", baseURL: "http://127.0.0.2:1",
        api: "openai-completions", apiKeyExpression: "LOCAL_SECRET",
        authHeader: nil, headers: [:], models: [ModelSpec(
            id: fixture.modelID, providerID: fixture.providerID,
            json: .object(["id": .string(fixture.modelID)]),
            provider: .object([
                "api": .string("openai-completions"),
                "baseUrl": .string("http://127.0.0.2:1"),
            ]))])
    let changedModels = ModelsConfig(
        providers: [changedProvider], raw: .object([:]),
        fileURL: fixture.home.modelsFile, exists: true)
    let changedResolver = LocalWorkHostLaunchResolver(configuration: .init(
        home: fixture.home,
        workspaceRegistry: fixture.workspaceRegistry,
        runtimeRepositoryRoot: fixture.runtime,
        models: changedModels,
        auth: fixture.resolver.configuration.auth,
        environment: fixture.resolver.configuration.environment))
    XCTAssertFalse(changedResolver.canReconstruct(template))

    // Recovery probes must bind to the recorded filesystem identity, not merely to the locator
    // string stored in the Run-free template.
    try FileManager.default.removeItem(at: fixture.workspace)
    try FileManager.default.createDirectory(
        at: fixture.workspace, withIntermediateDirectories: true)
    XCTAssertFalse(fixture.resolver.canReconstruct(template))

    try FileManager.default.removeItem(at: fixture.runtime)
    XCTAssertFalse(fixture.resolver.canReconstruct(template))
}

func test_localWorkHostLaunchResolverProbeReopensDurablePromptFreeTemplate() throws {
    let fixture = try LocalResolverFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let draft = try fixture.resolver.draft(for: fixture.request())

    let store = WorkLaunchManifestStore(home: fixture.home)
    let host = try fixture.home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef("durable-session"),
        work: WorkRef(workHostID: host.workHostID, workID: "durable-work"),
        workHost: host,
        sessionAttachment: SessionAttachmentRef("durable-attachment"))
    let key = WorkLaunchCreateKey(
        client: ClientRef("resolver-test-client"),
        requestDigest: try WorkLaunchCreateKey.requestDigest(
            configuration: draft.configuration,
            requestedCapabilities: draft.requestedCapabilities),
        commandID: "resolver-create",
        causalControlCursor: JournalCursor(
            journal: .workHost(host), eventID: nil, sequence: 0))
    let retained = try store.retain(draft, for: key)
    let durable = try store.publishTemplate(retained, binding: binding)

    let recreated = LocalWorkHostLaunchResolver(configuration: .init(
        home: fixture.home,
        workspaceRegistry: fixture.workspaceRegistry,
        runtimeRepositoryRoot: fixture.runtime,
        models: fixture.resolver.configuration.models,
        auth: fixture.resolver.configuration.auth,
        environment: fixture.resolver.configuration.environment,
        preferences: fixture.resolver.configuration.preferences))
    let reopened = try XCTUnwrap(try store.readTemplate(for: binding.work))
    XCTAssertEqual(reopened, durable)
    XCTAssertTrue(recreated.canReconstruct(reopened))
}

func test_localWorkHostLaunchResolverReconfirmationRestoresSameTemplate() throws {
    let fixture = try LocalResolverFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (template, binding) = try fixture.template()
    let originalDigest = try template.template.contentDigest()
    XCTAssertTrue(fixture.resolver.canReconstruct(template))

    // Model an older persisted registry record whose raw device identity is stale. The launch
    // template remains unchanged: only the explicit workspace confirmation may refresh identity.
    try localResolverMutateLegacyDevice(home: fixture.home)
    XCTAssertFalse(fixture.resolver.canReconstruct(template))

    let prepared = try fixture.workspaceRegistry.prepareReconfirmation(
        workspaceID: fixture.workspaceID, directory: fixture.workspace)
    let confirmed = try fixture.workspaceRegistry.confirmReconfirmation(prepared)
    XCTAssertEqual(confirmed.workspaceID, fixture.workspaceID)
    XCTAssertEqual(confirmed.availability, .available)
    XCTAssertTrue(fixture.resolver.canReconstruct(template))
    XCTAssertEqual(try template.template.contentDigest(), originalDigest)
    XCTAssertEqual(template.template.draft.configuration.workspaceID, fixture.workspaceID)
    XCTAssertEqual(binding.workBinding.work, template.template.work)
}

func test_localWorkHostLaunchResolverServesQualifiedModelsThroughDurableSocket() async throws {
    let fixture = try LocalResolverFixture(
        modelID: "baseten/Qwen3-Coder-480B-A35B-Instruct")
    let socketNonce = UUID().uuidString.lowercased().prefix(12)
    let socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .resolvingSymlinksInPath()
        .appendingPathComponent("aw-\(socketNonce)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: socketRoot)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: fixture.home.root.path)
    let homePermissions = try FileManager.default.attributesOfItem(
        atPath: fixture.home.root.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(homePermissions?.intValue, 0o755)
    try FileManager.default.createDirectory(
        at: socketRoot, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])

    let clientRef = ClientRef("qualified-model-socket-client")
    let launchResolver = fixture.resolver
    let workspaceRegistry = fixture.workspaceRegistry
    let serviceResolver = WorkHostDaemonServiceResolver.durable(
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [clientRef: [.observe, .control]]),
        draftResolver: { request in try launchResolver.draft(for: request) },
        reconstructabilityProbe: launchResolver.reconstructabilityProbe,
        workspaceCatalogProvider: { try workspaceRegistry.catalog() })
    let coordinator = try WorkHostDaemonCoordinator(
        home: fixture.home, socketRoot: socketRoot,
        instanceID: "qualified-model-instance", startIdentity: "qualified-model-start",
        resolver: serviceResolver)
    var client: WorkServiceUnixSocketClient?
    do {
        let descriptor = try await localResolverStage("coordinator start") {
            try await coordinator.start()
        }
        let connected = WorkServiceUnixSocketClient(
            endpoint: descriptor.endpoint, client: clientRef,
            expectedHost: descriptor.hostInstance.host)
        client = connected
        let initial = try await localResolverStage("initial handshake") {
            try await connected.connect(build: "qualified-model-socket-test")
        }
        XCTAssertEqual(initial.workspaceCatalog.defaultWorkspace?.workspaceID, fixture.workspaceID)

        func request(
            commandID: String,
            cursor: JournalCursor,
            modelID: String?
        ) -> WorkServiceCreateWorkRequest {
            WorkServiceCreateWorkRequest(
                client: clientRef, commandID: commandID, causalControlCursor: cursor,
                configuration: WorkServiceWorkConfiguration(
                    providerID: fixture.providerID, modelID: modelID,
                    workspaceID: fixture.workspaceID),
                requestedCapabilities: [.observe, .control])
        }

        for unavailable in [
            request(
                commandID: "qualified-model-invalid", cursor: initial.controlCursor,
                modelID: "missing/model"),
            request(
                commandID: "qualified-model-missing", cursor: initial.controlCursor,
                modelID: nil),
        ] {
            do {
                _ = try await connected.createWork(unavailable)
                XCTFail("an unavailable model must be rejected before control admission")
            } catch let error as WorkServiceTransportError {
                guard case .remote(let code, let detail) = error else {
                    XCTFail("unexpected unavailable-model transport error: \(error)")
                    continue
                }
                XCTAssertEqual(code, .launchUnavailable)
                XCTAssertEqual(detail, "The requested in-house model is unavailable.")
            }
            let afterFailure = try await localResolverStage(
                "handshake after \(unavailable.commandID)") {
                    try await connected.handshake(
                        WorkServiceHandshakeRequest(client: clientRef))
                }
            XCTAssertEqual(afterFailure.controlCursor, initial.controlCursor)
            let empty = try await localResolverStage(
                "list after \(unavailable.commandID)") {
                    try await connected.listWorks(WorkServiceListRequest(client: clientRef))
                }
            XCTAssertTrue(empty.works.isEmpty)
        }

        let createRequest = request(
            commandID: "qualified-model-create", cursor: initial.controlCursor,
            modelID: fixture.modelID)
        let initialStart = try ServiceBackedCreateIntentStore.InitialStart(
            commandID: "qualified-model-start", prompt: "qualified model prompt")
        let created = try await localResolverStage("qualified-model socket Create") {
            try await connected.createWork(createRequest)
        }
        XCTAssertEqual(created.receipt.state, .accepted)
        XCTAssertEqual(created.work.configuration.modelID, fixture.modelID)
        XCTAssertEqual(created.work.execution, .idle)
        XCTAssertNil(created.work.currentRun)
        let exactKey = try XCTUnwrap(ServiceAttachmentKey(
            work: created.work.work, attachment: created.attachment))
        let createdStart = try ServiceBackedStartIntent(
            seed: initialStart, response: created, client: clientRef)
        let intentStore = try WorkServiceAttachedWorkIntentStore(
            home: fixture.home, key: exactKey)
        let createdController = try WorkServiceAttachedWorkController(
            service: connected, seed: .created(created), intentStore: intentStore)
        let createdProjection = try await localResolverStage("accepted controller refresh") {
            try await createdController.refresh()
        }
        XCTAssertTrue(createdProjection.isCanonical)
        XCTAssertEqual(createdProjection.descriptor.work, created.work.work)
        XCTAssertEqual(createdProjection.attachment.attachment, created.attachment.attachment)
        XCTAssertEqual(createdProjection.attachment.client, clientRef)
        XCTAssertEqual(createdProjection.attachment.session, created.session)
        XCTAssertEqual(createdProjection.attachment.sessionJournal, created.sessionJournal)
        XCTAssertEqual(
            createdProjection.attachment.sessionAttachment, created.sessionAttachment)
        XCTAssertEqual(
            ServiceAttachmentKey(
                work: createdProjection.descriptor.work,
                attachment: createdProjection.attachment),
            exactKey)
        XCTAssertTrue(createdStart.hasMatchingAttachment(in: createdProjection))

        let afterCreate = try await localResolverStage("post-Create handshake") {
            try await connected.handshake(WorkServiceHandshakeRequest(client: clientRef))
        }
        XCTAssertNotEqual(afterCreate.controlCursor, initial.controlCursor)

        let duplicate = try await localResolverStage("duplicate socket Create") {
            try await connected.createWork(createRequest)
        }
        XCTAssertEqual(duplicate.receipt.state, .duplicate)
        XCTAssertEqual(duplicate.work.work, created.work.work)
        XCTAssertEqual(duplicate.session, created.session)
        XCTAssertEqual(duplicate.sessionJournal, created.sessionJournal)
        XCTAssertEqual(duplicate.sessionAttachment, created.sessionAttachment)
        XCTAssertEqual(duplicate.attachment.attachment, created.attachment.attachment)
        XCTAssertEqual(duplicate.workCursor, created.workCursor)
        XCTAssertEqual(duplicate.sessionCursor, created.sessionCursor)
        XCTAssertEqual(duplicate.controlCursor, created.controlCursor)
        XCTAssertEqual(duplicate.receipt.resultingControlCursor, created.controlCursor)
        XCTAssertEqual(duplicate.receipt.authorization, created.receipt.authorization)
        XCTAssertEqual(duplicate.work.execution, .idle)
        XCTAssertNil(duplicate.work.currentRun)
        let duplicateStart = try ServiceBackedStartIntent(
            seed: initialStart, response: duplicate, client: clientRef)
        XCTAssertEqual(duplicateStart, createdStart)
        let duplicateController = try WorkServiceAttachedWorkController(
            service: connected, seed: .created(duplicate),
            intentStore: intentStore)
        let duplicateProjection = try await localResolverStage("duplicate controller refresh") {
            try await duplicateController.refresh()
        }
        XCTAssertTrue(duplicateProjection.isCanonical)
        XCTAssertEqual(duplicateProjection.descriptor.work, created.work.work)
        XCTAssertEqual(duplicateProjection.attachment.attachment, exactKey.clientAttachment)
        XCTAssertEqual(
            ServiceAttachmentKey(
                work: duplicateProjection.descriptor.work,
                attachment: duplicateProjection.attachment),
            exactKey)
        XCTAssertTrue(duplicateStart.hasMatchingAttachment(in: duplicateProjection))
        let afterDuplicate = try await localResolverStage("post-duplicate handshake") {
            try await connected.handshake(WorkServiceHandshakeRequest(client: clientRef))
        }
        XCTAssertEqual(afterDuplicate.controlCursor, afterCreate.controlCursor)
        let page = try await localResolverStage("final Work list") {
            try await connected.listWorks(WorkServiceListRequest(client: clientRef))
        }
        XCTAssertEqual(page.works.map(\.work), [created.work.work])

        // The controller refresh above advanced the shared control journal with read
        // acknowledgements. A later Create must retain that exact non-genesis cursor rather than
        // treating the first Create of the Host lifetime as the only valid launch key.
        let secondRequest = request(
            commandID: "qualified-model-create-after-control-progress",
            cursor: afterDuplicate.controlCursor,
            modelID: fixture.modelID)
        let second = try await localResolverStage("second socket Create after control progress") {
            try await connected.createWork(secondRequest)
        }
        XCTAssertEqual(second.receipt.state, .accepted)
        XCTAssertNotEqual(second.work.work, created.work.work)
        XCTAssertNotEqual(second.session, created.session)
        XCTAssertNotEqual(second.sessionJournal, created.sessionJournal)
        XCTAssertNotEqual(second.sessionAttachment, created.sessionAttachment)
        XCTAssertNotEqual(second.attachment.attachment, created.attachment.attachment)

        let afterSecond = try await localResolverStage("post-second-Create handshake") {
            try await connected.handshake(WorkServiceHandshakeRequest(client: clientRef))
        }
        XCTAssertNotEqual(afterSecond.controlCursor, afterDuplicate.controlCursor)
        let secondDuplicate = try await localResolverStage("duplicate second socket Create") {
            try await connected.createWork(secondRequest)
        }
        XCTAssertEqual(secondDuplicate.receipt.state, .duplicate)
        XCTAssertEqual(secondDuplicate.work.work, second.work.work)
        XCTAssertEqual(secondDuplicate.session, second.session)
        XCTAssertEqual(secondDuplicate.sessionJournal, second.sessionJournal)
        XCTAssertEqual(secondDuplicate.sessionAttachment, second.sessionAttachment)
        XCTAssertEqual(secondDuplicate.attachment.attachment, second.attachment.attachment)
        XCTAssertEqual(secondDuplicate.workCursor, second.workCursor)
        XCTAssertEqual(secondDuplicate.sessionCursor, second.sessionCursor)
        XCTAssertEqual(secondDuplicate.controlCursor, second.controlCursor)
        XCTAssertEqual(secondDuplicate.receipt.resultingControlCursor, second.controlCursor)
        let afterSecondDuplicate = try await localResolverStage(
            "post-second-duplicate handshake") {
                try await connected.handshake(WorkServiceHandshakeRequest(client: clientRef))
            }
        XCTAssertEqual(afterSecondDuplicate.controlCursor, afterSecond.controlCursor)

        // A new command cannot reuse the launch-time cursor after later control mutations. The
        // durable socket must preserve that typed stale result without reserving another Work or
        // advancing the control journal; exact duplicates remain lookups of their original Works.
        let staleRequest = request(
            commandID: "qualified-model-new-command-at-stale-cursor",
            cursor: initial.controlCursor,
            modelID: fixture.modelID)
        do {
            _ = try await connected.createWork(staleRequest)
            XCTFail("a new Create at a stale control cursor must be rejected")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .staleCursor)
        }
        let afterStale = try await localResolverStage("post-stale-Create handshake") {
            try await connected.handshake(WorkServiceHandshakeRequest(client: clientRef))
        }
        XCTAssertEqual(afterStale.controlCursor, afterSecondDuplicate.controlCursor)

        let firstDuplicateAfterStale = try await localResolverStage(
            "first duplicate after stale Create") {
                try await connected.createWork(createRequest)
            }
        XCTAssertEqual(firstDuplicateAfterStale.receipt.state, .duplicate)
        XCTAssertEqual(firstDuplicateAfterStale.work.work, created.work.work)
        XCTAssertEqual(firstDuplicateAfterStale.session, created.session)
        XCTAssertEqual(firstDuplicateAfterStale.attachment.attachment, created.attachment.attachment)
        let secondDuplicateAfterStale = try await localResolverStage(
            "second duplicate after stale Create") {
                try await connected.createWork(secondRequest)
            }
        XCTAssertEqual(secondDuplicateAfterStale.receipt.state, .duplicate)
        XCTAssertEqual(secondDuplicateAfterStale.work.work, second.work.work)
        XCTAssertEqual(secondDuplicateAfterStale.session, second.session)
        XCTAssertEqual(secondDuplicateAfterStale.attachment.attachment, second.attachment.attachment)
        let afterPostStaleDuplicates = try await localResolverStage(
            "post-stale-duplicates handshake") {
                try await connected.handshake(WorkServiceHandshakeRequest(client: clientRef))
            }
        XCTAssertEqual(afterPostStaleDuplicates.controlCursor, afterStale.controlCursor)

        let twoWorkPage = try await localResolverStage("two-Work final list") {
            try await connected.listWorks(WorkServiceListRequest(client: clientRef))
        }
        XCTAssertEqual(Set(twoWorkPage.works.map(\.work)), Set([created.work.work, second.work.work]))
        await connected.close()
        client = nil
        await coordinator.forceStop()
    } catch {
        await client?.close()
        await coordinator.forceStop()
        throw error
    }
}

let casesLocalWorkHostLaunchResolver: [Case] = [
    ("phase3 local launch resolver: default and qualified model", {
        try test_localWorkHostLaunchResolverSelectsDefaultAndQualifiedModels()
    }),
    ("phase3 local launch resolver: workspace and runtime bounds", {
        try test_localWorkHostLaunchResolverBoundsWorkspaceAndRuntime()
    }),
    ("phase3 local launch resolver: drafts contain no credentials", {
        try test_localWorkHostLaunchResolverDraftDoesNotPersistCredentials()
    }),
    ("phase3 local launch resolver: exact Run bodies materialize", {
        try await test_localWorkHostLaunchResolverMaterializesExactRunBodies()
    }),
    ("phase3 local launch resolver: probe fails closed", {
        try test_localWorkHostLaunchResolverProbeIsBoundedAndFailsClosed()
    }),
    ("phase3 local launch resolver: durable prompt-free template reopens", {
        try test_localWorkHostLaunchResolverProbeReopensDurablePromptFreeTemplate()
    }),
    ("phase3 local launch resolver: reconfirmation restores same template", {
        try test_localWorkHostLaunchResolverReconfirmationRestoresSameTemplate()
    }),
    ("phase3 local launch resolver: qualified model survives durable socket Create", {
        try await test_localWorkHostLaunchResolverServesQualifiedModelsThroughDurableSocket()
    }),
]
