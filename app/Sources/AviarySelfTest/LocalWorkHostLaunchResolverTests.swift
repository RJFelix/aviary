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

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-local-resolver-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        runtime = root.appending(path: "runtime", directoryHint: .isDirectory)
        providerID = "local-provider"
        modelID = "local-model"
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
]
