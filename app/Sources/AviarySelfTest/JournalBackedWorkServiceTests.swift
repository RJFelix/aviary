import Foundation
@testable import AviaryCore

/// Small host-private resolver used by the composition tests.  It intentionally does not retain
/// a prompt or a path: those belong to the real WorkLaunchManifestStore adapter.  The service
/// still refuses to create when this seam is absent, which protects restart reconstruction from
/// treating control-journal digests as executable material.
private actor JournalBackedTestManifestStore: JournalBackedWorkServiceLaunchManifestStore {
    private let digest: String
    private let expectedInputDigest: String?
    private let productionCapable: Bool
    private let simulateUnstartedReservation: Bool
    private let draft: WorkLaunchManifestDraft
    private var failAfterTemplatePublication: Bool
    private var templates: [WorkRef: WorkLaunchWorkTemplateRecord] = [:]
    private var starts: [WorkRef: WorkLaunchManifestRecord] = [:]
    private var selections: [WorkRef: WorkLaunchManifestRecord] = [:]
    private var startReservations: [WorkRef: WorkLaunchStartReservation] = [:]

    init(
        productionCapable: Bool = false,
        failAfterTemplatePublication: Bool = false,
        expectedPrompt: String? = nil,
        simulateUnstartedReservation: Bool = false
    ) {
        if let expectedPrompt {
            digest = "sha256:" + AviarySHA256.hash(data: Data(expectedPrompt.utf8))
                .map { String(format: "%02x", $0) }.joined()
            expectedInputDigest = digest
        } else {
            digest = "sha256:" + String(repeating: "a", count: 64)
            expectedInputDigest = nil
        }
        self.productionCapable = productionCapable
        self.simulateUnstartedReservation = simulateUnstartedReservation
        self.failAfterTemplatePublication = failAfterTemplatePublication
        draft = WorkLaunchManifestDraft(
            workspace: WorkLaunchWorkspace(
                locator: "/tmp/aviary-journal-service",
                policy: .temporary),
            runtime: WorkLaunchRuntime(
                providerID: "test-provider", modelID: "test-model", runtimeVariant: "test"),
            configuration: .init(),
            requestedCapabilities: [],
            provenance: WorkLaunchManifestProvenance(source: "journal-service-test"))
    }

    func retain(
        _ request: WorkServiceCreateWorkRequest
    ) async throws -> JournalBackedWorkLaunchManifest {
        return JournalBackedWorkLaunchManifest(
            bodyDigest: digest, configurationDigest: digest,
            launchMetadata: WorkHostLaunchMetadata(
                providerID: request.configuration.providerID,
                modelID: request.configuration.modelID),
            hostedConfiguration: productionResolver())
    }

    func resolve(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> JournalBackedWorkLaunchManifest? {
        guard let template = templates[work],
              template.binding.session == session,
              template.binding.sessionAttachment == sessionAttachment else { return nil }
        return JournalBackedWorkLaunchManifest(
            bodyDigest: digest, configurationDigest: template.digest,
            launchMetadata: WorkHostLaunchMetadata(
                providerID: template.template.draft.runtime.providerID,
                modelID: template.template.draft.runtime.modelID),
            hostedConfiguration: productionResolver(), template: template)
    }

    func bindTemplate(
        _ manifest: JournalBackedWorkLaunchManifest,
        binding: WorkBinding
    ) async throws -> JournalBackedWorkLaunchManifest {
        if let existing = templates[binding.work] {
            guard existing.binding == binding else { throw WorkServiceProtocolError.journalMismatch }
            return JournalBackedWorkLaunchManifest(
                bodyDigest: digest, configurationDigest: existing.digest,
                launchMetadata: WorkHostLaunchMetadata(
                    providerID: existing.template.draft.runtime.providerID,
                    modelID: existing.template.draft.runtime.modelID),
                template: existing)
        }
        let templateKey: WorkLaunchCreateKey
        if let retainedKey = manifest.retainedRecord?.key {
            templateKey = retainedKey
        } else {
            templateKey = WorkLaunchCreateKey(
                client: ClientRef("test-template"),
                requestDigest: try WorkLaunchCreateKey.requestDigest(
                    configuration: draft.configuration,
                    requestedCapabilities: draft.requestedCapabilities),
                commandID: "test-template",
                causalControlCursor: JournalCursor(
                    journal: JournalRef.work(binding.work), sequence: 2))
        }
        let template = WorkLaunchWorkTemplate(
            binding: binding, draft: draft, retentionKey: templateKey)
        let bytes = try template.canonicalBytes()
        let templateRecord = WorkLaunchWorkTemplateRecord(
            template: template,
            generation: WorkLaunchWorkTemplateGeneration(generation: 1, digest: digest),
            templateByteCount: bytes.count)
        templates[binding.work] = templateRecord
        if simulateUnstartedReservation {
            let reservationIntent = WorkLaunchStartIntent(
                client: ClientRef("creator"), commandID: "unstarted-reservation",
                causalWorkCursor: JournalCursor(
                    journal: JournalRef.work(binding.work), sequence: 2),
                bodyDigest: "sha256:" + AviarySHA256.hash(data: Data())
                    .map { String(format: "%02x", $0) }.joined())
            let runBinding = WorkRunBinding(workBinding: binding, run: RunRef("unstarted-run"))
            let manifest = try draft.bind(
                to: runBinding, startIntent: reservationIntent,
                initialInputBodyReference: nil)
            let record = WorkLaunchManifestRecord(
                manifest: manifest,
                generation: WorkLaunchManifestGeneration(generation: 1, digest: digest),
                manifestByteCount: try manifest.canonicalBytes().count)
            selections[binding.work] = record
        }
        if failAfterTemplatePublication {
            failAfterTemplatePublication = false
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return JournalBackedWorkLaunchManifest(
            bodyDigest: digest, configurationDigest: digest,
            launchMetadata: WorkHostLaunchMetadata(
                providerID: draft.runtime.providerID, modelID: draft.runtime.modelID),
            hostedConfiguration: productionResolver(), template: templateRecord)
    }

    func currentSelection(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> WorkLaunchManifestRecord? {
        guard let selection = selections[work],
              selection.manifest.identity.session == session,
              selection.manifest.identity.sessionAttachment == sessionAttachment else {
            return nil
        }
        return selection
    }

    func hasPendingStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> Bool {
        _ = (work, session, sessionAttachment)
        return false
    }

    func bindStart(
        _ manifest: JournalBackedWorkLaunchManifest,
        binding: WorkBinding,
        run: RunRef,
        intent: WorkLaunchStartIntent,
        body: Data,
        policy: WorkLaunchExecutionPolicy,
        selectedPromptAssembly: WorkLaunchPromptAssembly?
    ) async throws -> JournalBackedWorkLaunchManifest {
        guard let template = manifest.template, template.binding == binding else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        guard bodyDigest(body) == intent.bodyDigest else {
            throw WorkServiceProtocolError.invalidRequest(
                "Start input does not match its durable Start identity")
        }
        if let expectedInputDigest, bodyDigest(body) != expectedInputDigest {
            throw WorkServiceProtocolError.invalidRequest(
                "Start input does not match retained launch material")
        }
        if let existing = starts[binding.work] {
            if policy.projection == .reopenHistorical {
                starts.removeValue(forKey: binding.work)
            } else {
                guard existing.manifest.startIntent == intent else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                return manifestFromRecord(existing, template: template)
            }
        }
        let final = try template.template.draft.bind(
            to: WorkRunBinding(workBinding: binding, run: run), startIntent: intent)
            .withResumePolicy(policy.resumePolicy)
        let bytes = try final.canonicalBytes()
        let record = WorkLaunchManifestRecord(
            manifest: final,
            generation: WorkLaunchManifestGeneration(generation: 1, digest: digest),
            manifestByteCount: bytes.count)
        starts[binding.work] = record
        return manifestFromRecord(record, template: template)
    }

    func reserveStart(
        _ template: WorkLaunchWorkTemplateRecord,
        run: RunRef,
        intent: WorkLaunchStartIntent,
        expectedPrevious: WorkLaunchManifestGeneration?,
        initialInputBodyReference: TimelineBodyReference
    ) async throws -> WorkLaunchStartAdmission {
        let binding = template.binding
        if let existing = starts[binding.work] {
            guard existing.manifest.startIntent == intent,
                  existing.manifest.identity.run == run else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            return .existing(existing)
        }
        if let existing = startReservations[binding.work] {
            guard existing.intent == intent, existing.run == run,
                  existing.templateGeneration == template.generation,
                  existing.initialInputBodyReference == initialInputBodyReference else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            return .reserved(existing)
        }
        if let current = selections[binding.work] {
            guard current.generation == expectedPrevious else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
        } else if expectedPrevious != nil {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let reservation = WorkLaunchStartReservation(
            binding: binding, run: run, intent: intent,
            templateGeneration: template.generation,
            initialInputBodyReference: initialInputBodyReference,
            expectedPrevious: expectedPrevious)
        startReservations[binding.work] = reservation
        return .winner(reservation)
    }

    func prepareStart(
        _ reservation: WorkLaunchStartReservation,
        promptAssembly: WorkLaunchPromptAssembly
    ) async throws -> WorkLaunchStartReservation {
        guard let existing = startReservations[reservation.binding.work],
              existing.binding == reservation.binding,
              existing.run == reservation.run,
              existing.intent == reservation.intent,
              existing.templateGeneration == reservation.templateGeneration,
              existing.initialInputBodyReference == reservation.initialInputBodyReference,
              existing.expectedPrevious == reservation.expectedPrevious else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let prepared = WorkLaunchStartReservation(
            binding: existing.binding, run: existing.run, intent: existing.intent,
            templateGeneration: existing.templateGeneration,
            initialInputBodyReference: existing.initialInputBodyReference,
            expectedPrevious: existing.expectedPrevious, promptAssembly: promptAssembly)
        startReservations[reservation.binding.work] = prepared
        return prepared
    }

    func resolveStartReservation(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent
    ) async throws -> WorkLaunchStartReservation? {
        guard let reservation = startReservations[work],
              reservation.binding.session == session,
              reservation.binding.sessionAttachment == sessionAttachment,
              reservation.intent == intent else { return nil }
        return reservation
    }

    private func bodyDigest(_ body: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: body)
            .map { String(format: "%02x", $0) }.joined()
    }

    func resolveStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent
    ) async throws -> JournalBackedWorkLaunchManifest? {
        guard let record = starts[work],
              record.manifest.identity.session == session,
              record.manifest.identity.sessionAttachment == sessionAttachment,
              record.manifest.startIntent == intent,
              let template = templates[work] else { return nil }
        return manifestFromRecord(record, template: template)
    }

    func canReconstruct(
        _ manifest: JournalBackedWorkLaunchManifest
    ) async throws -> Bool {
        // The self-test resolver has no provider, but productionCapable is an explicit fixture
        // assertion that its injected host-private configuration probe succeeded.
        productionCapable && manifest.template != nil
    }

    private func manifestFromRecord(
        _ record: WorkLaunchManifestRecord,
        template: WorkLaunchWorkTemplateRecord
    ) -> JournalBackedWorkLaunchManifest {
        JournalBackedWorkLaunchManifest(
            bodyDigest: digest, configurationDigest: record.manifestDigest,
            launchMetadata: WorkHostLaunchMetadata(
                providerID: record.manifest.runtime.providerID,
                modelID: record.manifest.runtime.modelID),
            hostedConfiguration: productionResolver(),
            identity: record.manifest.identity, template: template, durableRecord: record)
    }

    private func productionResolver() ->
        (@Sendable (WorkRunBinding) -> HostedInHouseWorkConfiguration?)? {
        guard productionCapable else { return nil }
        return { _ in fatalError("Create must not open a production Hosted actor") }
    }
}

func testJournalBackedWorkServiceBindsPerRunStartInputAndAcceptsEmptyDigest() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let grants = journalBackedAllCapabilities()
    let store = JournalBackedTestManifestStore(expectedPrompt: "expected input")
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]),
        manifestStore: store)
    let cursor = try await service.handshake(WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-start-input", causalControlCursor: cursor,
        configuration: WorkServiceWorkConfiguration(
            providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .start]))
    do {
        _ = try await service.command(WorkServiceCommandRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, commandID: "start-mismatch",
            client: client, sessionAttachment: created.sessionAttachment,
            causalWorkCursor: created.workCursor, kind: .start, value: "different input"))
        XCTFail("a Start body mismatch must not reach Hosted admission")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }
    await service.controlJournal.close()

    // Start owns and retains its exact body. An empty Start is represented by nil at the service
    // boundary, but its durable identity still carries the SHA-256 digest of zero bytes.
    let (emptyHome, emptyRoot) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: emptyRoot) }
    let emptyStore = JournalBackedTestManifestStore(expectedPrompt: "")
    let emptyService = try JournalBackedWorkService(
        home: emptyHome,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]),
        manifestStore: emptyStore)
    let emptyCursor = try await emptyService.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let emptyCreated = try await emptyService.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-empty-input", causalControlCursor: emptyCursor,
        requestedCapabilities: [.observe, .control, .start]))
    do {
        _ = try await emptyService.command(WorkServiceCommandRequest(
            work: emptyCreated.work.work, journal: emptyCreated.work.journal,
            attachment: emptyCreated.attachment.attachment, commandID: "start-empty",
            client: client, sessionAttachment: emptyCreated.sessionAttachment,
            causalWorkCursor: emptyCreated.workCursor, kind: .start, value: nil))
        XCTFail("the test store has no Hosted resolver")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    await emptyService.controlJournal.close()
}

private func journalBackedAllCapabilities() -> Set<WorkServiceCapability> {
    Set(WorkServiceCapability.allCases)
}

/// The update retry test needs an authorizer which intentionally collapses two different
/// requested envelopes to the same granted set. The control journal must still retain the exact
/// request, or `observe` and `observe + start` would alias under one client-qualified command.
private struct JournalBackedSameGrantAuthorizer: WorkServiceAuthorizer {
    func authorization(
        for client: ClientRef, requested: Set<WorkServiceCapability>
    ) -> WorkServiceAuthorizationOutcome {
        _ = client
        let granted: Set<WorkServiceCapability>
        if requested == [.observe, .control] {
            granted = requested
        } else if requested == [.observe] || requested == [.observe, .start] {
            granted = [.observe]
        } else {
            granted = requested
        }
        return WorkServiceAuthorizationOutcome(
            requested: requested, granted: granted,
            denied: requested.subtracting(granted))
    }
}

private func journalBackedHome() throws -> (AgentHome, URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-journal-service-" + UUID().uuidString,
                   directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (AgentHome(root: root), root)
}

private actor JournalDraftResolutionCounter {
    private(set) var calls = 0

    func increment() { calls += 1 }
}

private actor JournalDraftRoute {
    private var providerID: String

    init(providerID: String) { self.providerID = providerID }

    func set(providerID: String) { self.providerID = providerID }

    func currentProviderID() -> String { providerID }
}

private actor JournalPromptRoute {
    private var value: String
    private(set) var calls = 0

    init(value: String) { self.value = value }

    func set(_ value: String) { self.value = value }

    func next() -> String {
        calls += 1
        return value
    }
}

private actor JournalCatalogProbeGate {
    private let catalog: WorkHostWorkspaceCatalog
    private var released = false
    private var pending: [CheckedContinuation<WorkHostWorkspaceCatalog, Never>] = []
    private var calls = 0

    init(catalog: WorkHostWorkspaceCatalog) {
        self.catalog = catalog
    }

    func read() async -> WorkHostWorkspaceCatalog {
        calls += 1
        if released { return catalog }
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }

    func callCount() -> Int { calls }

    func release() {
        released = true
        let continuations = pending
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(returning: catalog)
        }
    }
}

private func adapterPromptAssembly(_ text: String) throws -> SystemPromptAssembly {
    let source = try PromptSource(
        sourceID: "adapter:ambient", kind: .generated, label: "Adapter prompt",
        fullBody: text, deliveredBody: text, renderedBody: text)
    return try SystemPromptAssembly(text: text, sources: [source])
}

private func adapterDigest(_ data: Data) -> String {
    "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func testJournalBackedWorkspaceCatalogRefreshesPerHandshakeAndFailsClosed() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appending(path: "first", directoryHint: .isDirectory)
    let secondURL = root.appending(path: "second", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

    let registry = try WorkHostWorkspaceRegistry(home: home)
    let first = try registry.registerLocalDirectory(
        firstURL, label: "First", isDefault: true)
    let client = ClientRef("catalog-client")
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: JournalBackedTestManifestStore(),
        workspaceCatalogProvider: { try registry.catalog() })

    let initial = try await service.handshake(.init(client: client))
    XCTAssertEqual(initial.workspaceCatalog.entries.map(\.workspaceID), [first.workspaceID])
    XCTAssertEqual(initial.workspaceCatalog.defaultWorkspace?.workspaceID, first.workspaceID)

    let second = try registry.registerLocalDirectory(
        secondURL, label: "Second", isDefault: false)
    let promoted = try registry.registerLocalDirectory(
        secondURL, label: "Promoted", isDefault: true)
    let afterMutation = try await service.handshake(.init(client: client))
    XCTAssertEqual(
        afterMutation.workspaceCatalog.entries.map(\.workspaceID),
        [first.workspaceID, second.workspaceID].sorted {
            $0.rawValue < $1.rawValue
        })
    XCTAssertEqual(afterMutation.workspaceCatalog.defaultWorkspace?.workspaceID, promoted.workspaceID)
    XCTAssertEqual(
        afterMutation.workspaceCatalog.entries.first(where: { $0.workspaceID == second.workspaceID })?.label,
        "Promoted")

    try FileManager.default.removeItem(at: secondURL)
    let afterUnavailable = try await service.handshake(.init(client: client))
    XCTAssertEqual(
        afterUnavailable.workspaceCatalog.entries.first(where: { $0.workspaceID == second.workspaceID })?.availability,
        .unavailable)
    XCTAssertEqual(afterUnavailable.workspaceCatalog.defaultWorkspace?.workspaceID, second.workspaceID)

    try Data("not-json".utf8).write(to: home.workHostWorkspaceRegistryFile)
    let rejected = try await service.handshake(.init(client: client))
    XCTAssertFalse(rejected.accepted)
    XCTAssertEqual(rejected.workspaceCatalog, .empty)
    XCTAssertEqual(rejected.diagnostic, "workspace catalog unavailable")
    await service.controlJournal.close()
}

func testJournalBackedWorkspaceCatalogProbeIsBoundedAndShared() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("catalog-probe-client")
    let gate = JournalCatalogProbeGate(catalog: .empty)
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: JournalBackedTestManifestStore(),
        workspaceCatalogProvider: { await gate.read() },
        workspaceCatalogTimeoutNanoseconds: 25_000_000)

    // Start two handshakes against a provider which is deliberately waiting forever. Both must
    // fail closed at the bounded deadline, while an unrelated Work request continues through the
    // same service actor instead of waiting behind the catalog read.
    let firstTask = Task { try await service.handshake(.init(client: client)) }
    for _ in 0..<100 {
        if await gate.callCount() > 0 { break }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    let secondTask = Task { try await service.handshake(.init(client: client)) }
    let list = try await service.listWorks(.init(client: client))
    XCTAssertEqual(list.works, [])
    let first = try await firstTask.value
    let second = try await secondTask.value
    XCTAssertFalse(first.accepted)
    XCTAssertFalse(second.accepted)
    XCTAssertEqual(first.workspaceCatalog, .empty)
    XCTAssertEqual(second.workspaceCatalog, .empty)
    XCTAssertEqual(first.diagnostic, "workspace catalog unavailable")
    XCTAssertEqual(second.diagnostic, "workspace catalog unavailable")
    XCTAssertEqual(await gate.callCount(), 1,
                   "concurrent handshakes share one blocking catalog probe")

    // The timed-out provider is still fenced as one in-flight operation. Once it completes, the
    // next handshake observes a fresh successful catalog and no second detached probe was needed.
    await gate.release()
    let fresh = try await service.handshake(.init(client: client))
    XCTAssertTrue(fresh.accepted)
    XCTAssertEqual(fresh.workspaceCatalog, .empty)
    await service.controlJournal.close()
}

func testDurableStartAdapterReservesBeforeAssemblyAndReusesRecordedPrompt() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try home.requirePersistedWorkHost()
    let client = ClientRef("adapter-client")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control, .start]
    let route = JournalPromptRoute(value: "ambient-one")
    let draftResolver: DurableJournalBackedWorkLaunchManifestStore.DraftResolver = { request in
        WorkLaunchManifestDraft(
            workspace: WorkLaunchWorkspace(locator: "/tmp/adapter-start", policy: .temporary),
            runtime: WorkLaunchRuntime(
                providerID: "adapter-provider", modelID: "adapter-model", runtimeVariant: "test"),
            configuration: request.configuration,
            requestedCapabilities: request.requestedCapabilities,
            contextPolicy: WorkLaunchContextPolicy(),
            provenance: WorkLaunchManifestProvenance(source: "adapter-test"))
    }
    let promptResolver: DurableJournalBackedWorkLaunchManifestStore.PromptAssemblyResolver = {
        _, body, _ in
        let ambient = await route.next()
        let exact = "\(ambient)|\(String(decoding: body, as: UTF8.self))"
        return try adapterPromptAssembly(exact)
    }
    let store = WorkLaunchManifestStore(home: home)
    let durable = DurableJournalBackedWorkLaunchManifestStore(
        store: store, bodyAuthority: .workHost(host), draftResolver: draftResolver,
        promptAssemblyResolver: promptResolver)
    let create = WorkServiceCreateWorkRequest(
        client: client, commandID: "adapter-create",
        causalControlCursor: JournalCursor(journal: .workHost(host), eventID: nil, sequence: 0),
        configuration: WorkServiceWorkConfiguration(
            providerID: "adapter-provider", modelID: "adapter-model"),
        requestedCapabilities: capabilities)
    let retained = try await durable.retain(create)
    let binding = WorkBinding(
        session: SessionRef("adapter-session"),
        work: WorkRef(workHostID: host.workHostID, workID: "adapter-work"),
        workHost: host, sessionAttachment: SessionAttachmentRef("adapter-attachment"))
    let template = try await durable.bindTemplate(retained, binding: binding)
    let intent = WorkLaunchStartIntent(
        client: client, commandID: "adapter-start",
        causalWorkCursor: JournalCursor(journal: .work(binding.work), eventID: nil, sequence: 2),
        bodyDigest: adapterDigest(Data("exact-input".utf8)))
    let policy = WorkLaunchExecutionPolicy(projection: .fresh, modelContext: .launchFresh)
    let first = try await durable.bindStart(
        template, binding: binding, run: RunRef("adapter-run"), intent: intent,
        body: Data("exact-input".utf8), policy: policy)
    let firstRecord = try XCTUnwrap(first.durableRecord)
    let firstAssembly = try XCTUnwrap(firstRecord.manifest.promptAssembly)
    XCTAssertEqual(await route.calls, 1)
    XCTAssertEqual(
        try store.resolveSystemPromptBody(for: firstRecord.manifest),
        Data("ambient-one|exact-input".utf8))

    // A fresh adapter instance and changed ambient input must use the already-published Run record.
    await route.set("ambient-two")
    let restarted = DurableJournalBackedWorkLaunchManifestStore(
        store: WorkLaunchManifestStore(home: home), bodyAuthority: .workHost(host),
        draftResolver: { _ in throw WorkServiceProtocolError.sourceIncomplete },
        promptAssemblyResolver: { _, _, _ in
            XCTFail("duplicate Start must not invoke prompt assembly")
            return try adapterPromptAssembly("wrong")
        })
    let resolved = try await restarted.resolve(
        work: binding.work, session: binding.session,
        sessionAttachment: binding.sessionAttachment)
    let duplicate = try await restarted.bindStart(
        try XCTUnwrap(resolved), binding: binding, run: RunRef("adapter-run"), intent: intent,
        body: Data("exact-input".utf8), policy: policy)
    XCTAssertEqual(try XCTUnwrap(duplicate.durableRecord).manifest.promptAssembly, firstAssembly)
    XCTAssertEqual(await route.calls, 1)
}

func testDurableStartAssemblyCrashReservationFailsClosedWithoutReassembly() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try home.requirePersistedWorkHost()
    let client = ClientRef("crash-adapter-client")
    let draftResolver: DurableJournalBackedWorkLaunchManifestStore.DraftResolver = { request in
        WorkLaunchManifestDraft(
            workspace: WorkLaunchWorkspace(locator: "/tmp/crash-adapter", policy: .temporary),
            runtime: WorkLaunchRuntime(
                providerID: "crash-provider", modelID: "crash-model", runtimeVariant: "test"),
            configuration: request.configuration,
            requestedCapabilities: request.requestedCapabilities,
            provenance: WorkLaunchManifestProvenance(source: "crash-adapter-test"))
    }
    let route = JournalPromptRoute(value: "ambient-before-crash")
    let promptResolver: DurableJournalBackedWorkLaunchManifestStore.PromptAssemblyResolver = {
        _, _, _ in
        let value = await route.next()
        return try adapterPromptAssembly(value)
    }
    let store = WorkLaunchManifestStore(home: home)
    let durable = DurableJournalBackedWorkLaunchManifestStore(
        store: store, bodyAuthority: .workHost(host), draftResolver: draftResolver,
        promptAssemblyResolver: promptResolver)
    let create = WorkServiceCreateWorkRequest(
        client: client, commandID: "crash-adapter-create",
        causalControlCursor: JournalCursor(journal: .workHost(host), eventID: nil, sequence: 0),
        configuration: WorkServiceWorkConfiguration(
            providerID: "crash-provider", modelID: "crash-model"),
        requestedCapabilities: [.observe, .control, .start])
    let retained = try await durable.retain(create)
    let binding = WorkBinding(
        session: SessionRef("crash-adapter-session"),
        work: WorkRef(workHostID: host.workHostID, workID: "crash-adapter-work"),
        workHost: host, sessionAttachment: SessionAttachmentRef("crash-adapter-attachment"))
    let template = try await durable.bindTemplate(retained, binding: binding)
    let templateRecord = try XCTUnwrap(template.template)
    let body = Data("crash-input".utf8)
    let bodyReference = try ContextBodyStore(home: home).retain(body, authority: .workHost(host))
    let intent = WorkLaunchStartIntent(
        client: client, commandID: "crash-adapter-start",
        causalWorkCursor: JournalCursor(journal: .work(binding.work), eventID: nil, sequence: 2),
        bodyDigest: adapterDigest(body))
    let reservation = try store.reserveStart(
        templateRecord, run: RunRef("crash-adapter-run"), startIntent: intent,
        expectedPrevious: nil, initialInputBodyReference: bodyReference)
    guard case .winner = reservation else {
        XCTFail("the crash fixture must own the first Start reservation")
        return
    }
    await route.set("ambient-after-crash")
    do {
        _ = try await durable.bindStart(
            template, binding: binding, run: RunRef("crash-adapter-run"), intent: intent,
            body: body, policy: WorkLaunchExecutionPolicy(projection: .fresh, modelContext: .launchFresh))
        XCTFail("a reservation which crashed during assembly must remain recovery-required")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(await route.calls, 0)
}

/// A delivered Start remains a durable fact after the service/host instance disappears.  A new
/// service instance may replay the exact command receipt, but without the old registry actor it
/// must expose recovery-required and must not reopen Hosted, redispatch the provider, or mint a
/// second Run.
func testJournalBackedWorkServiceRestartReconcilesDeliveredStartWithoutRedispatch() async throws {
    guard let runtimeHost = try makeHost(.reference) else { return }
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try home.requirePersistedWorkHost()
    let client = ClientRef("restart-client")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control, .start]
    let route = JournalPromptRoute(value: "restart-ambient")
    let makeDurable: @Sendable () -> DurableJournalBackedWorkLaunchManifestStore = {
        DurableJournalBackedWorkLaunchManifestStore(
            store: WorkLaunchManifestStore(home: home), bodyAuthority: .workHost(host),
            draftResolver: { request in
                WorkLaunchManifestDraft(
                    workspace: WorkLaunchWorkspace(locator: "/tmp", policy: .temporary),
                    runtime: WorkLaunchRuntime(
                        providerID: "restart-provider", modelID: "restart-model",
                        runtimeVariant: "reference"),
                    configuration: request.configuration,
                    requestedCapabilities: request.requestedCapabilities,
                    provenance: WorkLaunchManifestProvenance(source: "restart-test"))
            },
            hostedResolver: { manifest, binding, policy in
                let retained = try WorkLaunchManifestStore(home: home)
                    .resolvePromptAssembly(for: manifest)
                var model = fakeModel()
                model.providerID = "restart-provider"
                model.id = "restart-model"
                return HostedInHouseWorkConfiguration(
                    home: home, cwd: "/tmp", model: model,
                    provider: JournalServiceRaceProvider(), runtimeHost: runtimeHost,
                    workRunBinding: binding, serviceActorID: "restart-test",
                    systemPrompt: retained.flattenedText,
                    systemPromptAssembly: retained,
                    projectionMode: policy.projection,
                    modelContextMode: policy.modelContext)
            },
            promptAssemblyResolver: { _, startBody, _ in
                let ambient = await route.next()
                let input = String(decoding: startBody, as: UTF8.self)
                return try adapterPromptAssembly("\(ambient)|\(input)")
            },
            reconstructabilityProbe: { _ in true })
    }

    let serviceA = try JournalBackedWorkService(
        home: home, instanceID: "restart-instance-a", startIdentity: "restart-start-a",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: capabilities]),
        manifestStore: makeDurable())
    let control = try await serviceA.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await serviceA.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "restart-create", causalControlCursor: control,
        configuration: WorkServiceWorkConfiguration(
            providerID: "restart-provider", modelID: "restart-model"),
        requestedCapabilities: capabilities))
    let start = try await serviceA.command(WorkServiceCommandRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, commandID: "restart-start",
        client: client, sessionAttachment: created.sessionAttachment,
        causalWorkCursor: created.workCursor, kind: .start, value: "restart-input"))
    XCTAssertEqual(start.state, .accepted)
    XCTAssertEqual(start.outcome, .started)
    XCTAssertEqual(start.hostProvenance, .current)
    let acceptedCursor = try XCTUnwrap(start.resultingWorkCursor)
    let acceptedHostSequence = try XCTUnwrap(start.hostSequence)

    let binding = WorkBinding(
        session: created.session, work: created.work.work, workHost: host,
        sessionAttachment: created.sessionAttachment)
    let launchStore = WorkLaunchManifestStore(home: home)
    let run1 = try XCTUnwrap(
        launchStore.readCurrentSelection(for: binding)?.record.manifest.identity.run)

    // Hosted Start is queued out of the public command call. Wait for its durable delivery before
    // discarding the first service, so the restart assertion covers an accepted+delivered Run.
    var delivered = false
    let deliveryDeadline = Date().addingTimeInterval(15)
    while Date() < deliveryDeadline && !delivered {
        let read = try TimelineJournalReader.read(
            Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work)),
            journal: created.work.journal,
            actor: TimelineActor(actorID: "restart-delivery-reader", kind: "self-test"),
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        delivered = read.records.map(\.event).contains {
            $0.type == TimelineEventType.commandDelivered && $0.run == run1
        }
        if !delivered { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    XCTAssertTrue(delivered, "restart fixture must durably deliver Start before service loss")
    let beforeRestartEvents = try TimelineJournalReader.read(
        Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work)),
        journal: created.work.journal,
        actor: TimelineActor(actorID: "restart-before-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertEqual(beforeRestartEvents.filter { $0.type == TimelineEventType.runStarted }.count, 1)
    XCTAssertEqual(await route.calls, 1)

    // Closing the old control journal models the service generation ending. Its registry/Hosted
    // actor is not supplied to the replacement service, so identity alone cannot be a liveness
    // proof. The control journal remains the durable source of the original command receipt.
    await serviceA.controlJournal.close()
    let serviceB = try JournalBackedWorkService(
        home: home, instanceID: "restart-instance-b", startIdentity: "restart-start-b",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: capabilities]),
        manifestStore: makeDurable())
    let duplicate = try await serviceB.command(WorkServiceCommandRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, commandID: "restart-start",
        client: client, sessionAttachment: created.sessionAttachment,
        causalWorkCursor: created.workCursor, kind: .start, value: "restart-input"))
    XCTAssertEqual(duplicate.state, .duplicate)
    XCTAssertEqual(duplicate.outcome, .startRecoveryRequired)
    XCTAssertEqual(duplicate.recoveryState, .delivered)
    XCTAssertEqual(duplicate.hostProvenance, .unknown)
    XCTAssertEqual(duplicate.causalWorkCursor, start.causalWorkCursor)
    XCTAssertEqual(duplicate.resultingWorkCursor, acceptedCursor)
    XCTAssertEqual(duplicate.hostSequence, acceptedHostSequence)
    XCTAssertEqual(duplicate.work, start.work)
    XCTAssertEqual(duplicate.commandID, start.commandID)
    XCTAssertEqual(duplicate.authorization, start.authorization)
    XCTAssertEqual(duplicate.rejection, start.rejection)

    let afterRestartEvents = try TimelineJournalReader.read(
        Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work)),
        journal: created.work.journal,
        actor: TimelineActor(actorID: "restart-after-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertEqual(afterRestartEvents.filter { $0.type == TimelineEventType.runStarted }.count, 1)
    XCTAssertEqual(afterRestartEvents.filter { $0.type == TimelineEventType.commandAccepted }.count,
                   beforeRestartEvents.filter { $0.type == TimelineEventType.commandAccepted }.count)
    XCTAssertEqual(afterRestartEvents.filter { $0.type == TimelineEventType.commandDelivered }.count,
                   beforeRestartEvents.filter { $0.type == TimelineEventType.commandDelivered }.count)
    XCTAssertEqual(await route.calls, 1, "restart duplicate must not reassemble ambient prompt")
    await serviceB.controlJournal.close()
}

private struct JournalReservationProvider: ChatProvider {
    let id = "journal-reservation-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

/// Holds a real public Start at each of the two service-owned suspension windows: prompt
/// assembly (before Run publication) and Hosted admission (after run.started, before command
/// acceptance). The test uses these gates to distinguish an exact duplicate from a same-body
/// request carrying the newer causal cursor.
private actor JournalStartGate {
    private(set) var entries = 0
    private var released = false

    func enterAndWait() async {
        entries += 1
        while !released {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func waitUntilEntered(_ expected: Int = 1) async {
        while entries < expected {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func release() {
        released = true
    }
}

private struct JournalServiceRaceProvider: ChatProvider {
    let id = "journal-service-race-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: "race-test"))
            continuation.finish()
        }
    }
}

private func journalServiceRaceAssembly() throws -> SystemPromptAssembly {
    let text = "journal service exact prompt"
    return try SystemPromptAssembly(text: text, sources: [
        try PromptSource(
            sourceID: "journal-service-race-source", kind: .generated,
            label: "race test source", fullBody: text, deliveredBody: text,
            renderedBody: text)
    ])
}

private func reservationHostedWork(
    home: AgentHome, work: WorkRef, runID: String, runtimeHost: RuntimeHost
) async throws -> HostedInHouseWork {
    let host = try home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef("reservation-session-\(work.workID)"), work: work,
        workHost: host, sessionAttachment: SessionAttachmentRef(
            "reservation-attachment-\(work.workID)"))
    _ = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "reservation-control-\(work.workID)")
    return try await HostedInHouseWork.open(configuration: HostedInHouseWorkConfiguration(
        home: home, cwd: "/tmp", model: fakeModel(), provider: JournalReservationProvider(),
        runtimeHost: runtimeHost,
        workRunBinding: WorkRunBinding(workBinding: binding, run: RunRef(runID)),
        serviceActorID: "journal-reservation-service", systemPrompt: "reservation"))
}

private func reservationStop(_ work: HostedInHouseWork, commandID: String) async {
    let snapshot = await work.snapshot()
    guard snapshot.lifecycle != .ended, let cursor = snapshot.latestWorkCursor else { return }
    _ = try? await work.submit(HostedInHouseWorkCommand(
        work: snapshot.identity.work, session: SessionRef(snapshot.identity.sessionID),
        sessionAttachment: snapshot.sessionAttachment, client: ClientRef("reservation-cleanup"),
        commandID: commandID, causalCursor: cursor, command: .endRun))
    for _ in 0..<200 {
        if (await work.snapshot()).lifecycle == .ended { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

func testJournalBackedWorkServiceRequiresLaunchMaterial() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]))
    let cursor = try await service.handshake(WorkServiceHandshakeRequest(client: client)).controlCursor
    do {
        _ = try await service.createWork(WorkServiceCreateWorkRequest(
            client: client, commandID: "create-without-manifest",
            causalControlCursor: cursor))
        XCTFail("creation without a host-private manifest must fail closed")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceCreateStaysIdleWithProductionManifest() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: JournalBackedTestManifestStore(productionCapable: true))
    let cursor = try await service.handshake(WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-production-idle", causalControlCursor: cursor,
        configuration: WorkServiceWorkConfiguration(
            providerID: "provider", modelID: "model")))
    XCTAssertEqual(created.work.execution, .idle)
    XCTAssertNil(created.work.currentRun)
    XCTAssertEqual(created.workCursor.sequence, 2)
    let source = try Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work))
    let events = TimelineJournalReader.read(
        source, journal: created.work.journal,
        actor: TimelineActor(actorID: "test-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertFalse(events.contains { $0.type == TimelineEventType.runStarted })
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceDoesNotProjectPreMarkerStartAsIdle() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let store = JournalBackedTestManifestStore(
        productionCapable: true, simulateUnstartedReservation: true)
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: store)
    let cursor = try await service.handshake(WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-pre-marker", causalControlCursor: cursor,
        requestedCapabilities: journalBackedAllCapabilities()))

    // The fake store exposes an exact Run-bound selection but no native run.started marker. This
    // is the crash window between durable Start publication and the opener. It is recovery work,
    // never an idle/reconstructable Work and never a positive liveness observation.
    await service.controlJournal.close()
    let restarted = try JournalBackedWorkService(
        home: home,
        instanceID: "pre-marker-restart",
        startIdentity: "pre-marker-restart",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: store)
    let recovery = try await restarted.scanRecovery()
    XCTAssertEqual(recovery.count, 1)
    XCTAssertEqual(recovery[0].work, created.work.work)
    XCTAssertEqual(recovery[0].disposition, .recoveryRequired)
    let described = try await restarted.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: client))
    XCTAssertEqual(described.execution, .recoveryRequired)

    // The durable reservation is not an idle Work and cannot be advanced by another command.
    // In particular, terminal commands must not use their unconditional cursor exception to
    // bypass the recovery fence.
    let attachment = created.attachment.attachment
    let workCursor = created.workCursor
    for (kind, commandID) in [
        (WorkServiceCommandKind.start, "different-start"),
        (.complete, "complete-during-recovery"),
        (.destroy, "destroy-during-recovery"),
    ] {
        do {
            _ = try await restarted.command(WorkServiceCommandRequest(
                work: created.work.work, journal: created.work.journal,
                attachment: attachment, commandID: commandID, client: client,
                sessionAttachment: created.sessionAttachment,
                causalWorkCursor: workCursor, kind: kind,
                value: kind == .start ? "different prompt" : nil))
            XCTFail("\(kind) must remain fail-closed while the Start reservation is unproven")
        } catch WorkServiceProtocolError.sourceIncomplete {
            XCTAssertTrue(true)
        }
    }
    await restarted.controlJournal.close()
}

func testJournalBackedWorkServiceListRequiresObserveCapability() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = ClientRef("creator")
    let viewer = ClientRef("viewer")
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [creator: [.observe, .control], viewer: [.control]]),
        manifestStore: JournalBackedTestManifestStore())
    let cursor = try await service.handshake(WorkServiceHandshakeRequest(client: creator)).controlCursor
    _ = try await service.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "create-list-observe", causalControlCursor: cursor))
    do {
        _ = try await service.listWorks(WorkServiceListRequest(client: viewer))
        XCTFail("list must require observe authorization")
    } catch WorkServiceProtocolError.capabilityDenied(.observe) {
        XCTAssertTrue(true)
    }
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceListIsolatesUnavailableDescriptorAndProgresses() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let store = JournalBackedTestManifestStore(productionCapable: true)
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: store)
    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let first = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-list-healthy", causalControlCursor: initial))
    let second = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-list-corrupt",
        causalControlCursor: first.controlCursor))

    // Keep the control projection intact but make only the lexically later Work source unreadable.
    // Creation IDs are host-minted and intentionally opaque, so order the pair before selecting
    // which row to corrupt. The inventory page must return the healthy row and consume the corrupt
    // row's source-page position so a caller can make deterministic progress.
    let ordered = [first.work.work, second.work.work].sorted { $0.workID < $1.workID }
    let corruptURL = home.timelineV2WorkJournalURL(ordered[1])
    try FileManager.default.removeItem(at: corruptURL)

    let firstPage = try await service.listWorks(WorkServiceListRequest(
        client: client, pageSize: 1))
    XCTAssertEqual(firstPage.works.map(\.work), [ordered[0]])
    XCTAssertEqual(firstPage.omissions, [])
    XCTAssertEqual(firstPage.nextPageToken, "1")

    let secondPage = try await service.listWorks(WorkServiceListRequest(
        client: client, pageSize: 1, pageToken: firstPage.nextPageToken))
    XCTAssertTrue(secondPage.works.isEmpty)
    XCTAssertEqual(secondPage.omissions.count, 1)
    XCTAssertEqual(secondPage.omissions[0].category, "work_descriptors")
    XCTAssertEqual(secondPage.omissions[0].count, 1)
    XCTAssertNil(secondPage.nextPageToken)
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceRecoveryNeverProjectsUnprovenRunAsLive() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let store = JournalBackedTestManifestStore()
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: store)
    let cursor = try await service.handshake(WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-recovery", causalControlCursor: cursor))
    let binding = WorkRunBinding(
        workBinding: WorkBinding(
            session: created.session, work: created.work.work,
            workHost: WorkHostRef(created.work.work.workHostID),
            sessionAttachment: created.sessionAttachment),
        run: RunRef("run-unproven"))
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, binding: binding, actorID: "recovery-test")
    try await bundle.closeChecked()
    await service.controlJournal.close()

    let restarted = try JournalBackedWorkService(
        home: home,
        instanceID: "instance-recovery",
        startIdentity: "start-recovery",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: store)
    let scan = try await restarted.scanRecovery()
    XCTAssertEqual(scan.count, 1)
    XCTAssertEqual(scan[0].disposition, .recoveryRequired)
    let descriptor = try await restarted.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: client))
    XCTAssertEqual(descriptor.execution, .recoveryRequired)
    XCTAssertEqual(descriptor.hostObservation?.reachability, .recovering)
    await restarted.controlJournal.close()
}

func testJournalBackedWorkServiceRetriesCrashAfterTemplatePublication() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let store = JournalBackedTestManifestStore(failAfterTemplatePublication: true)
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: journalBackedAllCapabilities()]),
        manifestStore: store)
    let cursor = try await service.handshake(WorkServiceHandshakeRequest(client: client)).controlCursor
    let request = WorkServiceCreateWorkRequest(
        client: client, commandID: "create-template-crash", causalControlCursor: cursor)
    do {
        _ = try await service.createWork(request)
        XCTFail("the injected post-template crash must interrupt the first response")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    let retry = try await service.createWork(request)
    XCTAssertEqual(retry.work.execution, .idle)
    XCTAssertEqual(retry.workCursor.sequence, 2)
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceRepairsReservationWithoutRerunningResolver() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control]
    let counter = JournalDraftResolutionCounter()
    let host = try home.requirePersistedWorkHost()
    let draftResolver: DurableJournalBackedWorkLaunchManifestStore.DraftResolver = { request in
        await counter.increment()
        return WorkLaunchManifestDraft(
            workspace: WorkLaunchWorkspace(
                locator: "/tmp/aviary-journal-service-recovery",
                policy: .temporary),
            runtime: WorkLaunchRuntime(
                providerID: request.configuration.providerID ?? "resolved-provider",
                modelID: request.configuration.modelID ?? "resolved-model",
                runtimeVariant: "test"),
            configuration: request.configuration,
            requestedCapabilities: request.requestedCapabilities,
            contextPolicy: WorkLaunchContextPolicy(
                includeContextFiles: request.configuration.includeContextFiles),
            recordingPolicy: WorkLaunchRecordingPolicy(
                recordPayloads: request.configuration.recordPayloads),
            resumePolicy: WorkLaunchResumePolicy(
                mode: WorkLaunchResumeMode(rawValue: request.configuration.resumePolicy ?? "")
                    ?? .fresh),
            reasoningPolicy: WorkLaunchReasoningPolicy(
                enabled: false, level: request.configuration.thinkingLevel),
            provenance: WorkLaunchManifestProvenance(source: "journal-service-recovery-test"))
    }
    let durable = DurableJournalBackedWorkLaunchManifestStore(
        store: WorkLaunchManifestStore(home: home),
        bodyAuthority: .work(WorkRef(workHostID: host.workHostID, workID: "body")),
        draftResolver: draftResolver)
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: capabilities]),
        manifestStore: durable)
    let controlCursor = try await service.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let request = WorkServiceCreateWorkRequest(
        client: client, commandID: "create-reservation-crash",
        causalControlCursor: controlCursor, requestedCapabilities: capabilities)

    // Simulate the crash after control reservation but before template publication. Retention is
    // durable, while the control reservation is the only visible Create fact at this point.
    let retained = try await durable.retain(request)
    let reservation = try await service.controlJournal.reserveCreation(
        WorkHostControlCreationRequest(
            client: client, commandID: request.commandID,
            bodyDigest: retained.bodyDigest,
            configurationDigest: retained.configurationDigest,
            causalControlCursor: controlCursor))
    XCTAssertEqual(reservation.work.workHostID, host.workHostID)

    let repaired = try await service.createWork(request)
    XCTAssertEqual(repaired.work.execution, .idle)
    XCTAssertEqual(repaired.work.work, reservation.work)
    XCTAssertEqual(await counter.calls, 1)
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceRecoversRetainedDraftBeforeReservation() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control]
    let counter = JournalDraftResolutionCounter()
    let route = JournalDraftRoute(providerID: "original-provider")
    let host = try home.requirePersistedWorkHost()
    let draftResolver: DurableJournalBackedWorkLaunchManifestStore.DraftResolver = { request in
        await counter.increment()
        return WorkLaunchManifestDraft(
            workspace: WorkLaunchWorkspace(
                locator: "/tmp/aviary-journal-service-retained-before-reservation",
                policy: .temporary),
            runtime: WorkLaunchRuntime(
                providerID: await route.currentProviderID(),
                modelID: "resolved-model", runtimeVariant: "test"),
            configuration: request.configuration,
            requestedCapabilities: request.requestedCapabilities,
            contextPolicy: WorkLaunchContextPolicy(
                includeContextFiles: request.configuration.includeContextFiles),
            recordingPolicy: WorkLaunchRecordingPolicy(
                recordPayloads: request.configuration.recordPayloads),
            resumePolicy: WorkLaunchResumePolicy(
                mode: WorkLaunchResumeMode(rawValue: request.configuration.resumePolicy ?? "")
                    ?? .fresh),
            reasoningPolicy: WorkLaunchReasoningPolicy(
                enabled: false, level: request.configuration.thinkingLevel),
            provenance: WorkLaunchManifestProvenance(source: "journal-service-retained-test"))
    }
    let durable = DurableJournalBackedWorkLaunchManifestStore(
        store: WorkLaunchManifestStore(home: home),
        bodyAuthority: .work(WorkRef(workHostID: host.workHostID, workID: "body")),
        draftResolver: draftResolver)
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: capabilities]),
        manifestStore: durable)
    let controlCursor = try await service.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let request = WorkServiceCreateWorkRequest(
        client: client, commandID: "create-retained-before-reservation",
        causalControlCursor: controlCursor, requestedCapabilities: capabilities)

    // Simulate a crash after retention but before the control reservation. A changed request
    // sharing the same caller command/cursor is rejected as a conflict, while the exact retry
    // reloads the original draft before the ambient route is consulted.
    let sameDraftDifferentCommand = WorkServiceCreateWorkRequest(
        client: client, commandID: "create-retained-different-command",
        causalControlCursor: request.causalControlCursor,
        requestedCapabilities: capabilities)
    _ = try await durable.retain(sameDraftDifferentCommand)
    let retainedPrimary: JournalBackedWorkLaunchManifest
    do {
        retainedPrimary = try await durable.retain(request)
    } catch {
        XCTFail("initial retention failed: \(error)")
        await service.controlJournal.close()
        return
    }
    let changed = WorkServiceCreateWorkRequest(
        client: client, commandID: request.commandID,
        causalControlCursor: request.causalControlCursor,
        requestedCapabilities: capabilities.union([.start]))
    do {
        _ = try await durable.retain(changed)
        XCTFail("changed Create identity must not create a second retention pointer")
    } catch let error as WorkLaunchManifestStoreError {
        XCTAssertEqual(error, .requestConflict)
    }
    await route.set(providerID: "changed-provider")

    // Make the crash boundary explicit: both identical drafts are durable, but only the primary
    // command has a control reservation. Recovery must use that reservation's full identity when
    // choosing among the two retained request pointers.
    _ = try await service.controlJournal.reserveCreation(
        WorkHostControlCreationRequest(
            client: client, commandID: request.commandID,
            bodyDigest: retainedPrimary.bodyDigest,
            configurationDigest: retainedPrimary.configurationDigest,
            causalControlCursor: controlCursor))

    let created: WorkServiceCreateWorkResponse
    do {
        created = try await service.createWork(request)
    } catch {
        XCTFail("exact Create retry failed: \(error)")
        await service.controlJournal.close()
        return
    }
    XCTAssertEqual(created.work.execution, .idle)
    XCTAssertEqual(await counter.calls, 3)
    let resolved = try await durable.resolve(
        work: created.work.work, session: created.session,
        sessionAttachment: created.sessionAttachment)
    XCTAssertEqual(resolved?.launchMetadata.providerID, "original-provider")
    XCTAssertEqual(
        resolved?.template?.template.retentionKey.commandID, request.commandID,
        "post-reservation recovery must select the exact command, not another identical draft")
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceJoinsExactStartAndRejectsNewerCursor() async throws {
    guard let runtimeHost = try makeHost(.reference) else { return }
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try home.requirePersistedWorkHost()
    let client = ClientRef("race-client")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control, .start, .end]
    let promptGate = JournalStartGate()
    let hostedGate = JournalStartGate()
    let assembly = try journalServiceRaceAssembly()

    let draftResolver: DurableJournalBackedWorkLaunchManifestStore.DraftResolver = { request in
        WorkLaunchManifestDraft(
            workspace: WorkLaunchWorkspace(locator: "/tmp", policy: .temporary),
            runtime: WorkLaunchRuntime(
                providerID: "test-provider", modelID: "test-model", runtimeVariant: "python3"),
            configuration: request.configuration,
            requestedCapabilities: request.requestedCapabilities,
            budgetPolicy: WorkLaunchBudgetPolicy(
                maximumTurns: 1, maximumDepth: 1, childMaximumTurns: 1),
            provenance: WorkLaunchManifestProvenance(source: "journal-service-race"))
    }
    let hostedResolver: DurableJournalBackedWorkLaunchManifestStore.HostedConfigurationResolver = {
        manifest, binding, policy in
        let retained = try WorkLaunchManifestStore(home: home).resolvePromptAssembly(for: manifest)
        var model = fakeModel()
        model.providerID = "test-provider"
        return HostedInHouseWorkConfiguration(
            home: home, cwd: "/tmp", model: model,
            provider: JournalServiceRaceProvider(), runtimeHost: runtimeHost,
            workRunBinding: binding, serviceActorID: "journal-service-race",
            systemPrompt: retained.flattenedText, systemPromptAssembly: retained,
            maxDepth: 1, maxIterations: 1, childMaxIterations: 1,
            projectionMode: policy.projection, modelContextMode: policy.modelContext,
            startAdmissionGate: { await hostedGate.enterAndWait() })
    }
    let durable = DurableJournalBackedWorkLaunchManifestStore(
        store: WorkLaunchManifestStore(home: home), bodyAuthority: .workHost(host),
        draftResolver: draftResolver, hostedResolver: hostedResolver,
        promptAssemblyResolver: { _, _, _ in
            await promptGate.enterAndWait()
            return assembly
        }, reconstructabilityProbe: { _ in true })
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: capabilities]),
        manifestStore: durable)
    let control = try await service.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "race-create", causalControlCursor: control,
        configuration: WorkServiceWorkConfiguration(
            providerID: "test-provider", modelID: "test-model"), requestedCapabilities: capabilities))
    let start = WorkServiceCommandRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, commandID: "race-start", client: client,
        sessionAttachment: created.sessionAttachment, causalWorkCursor: created.workCursor,
        kind: .start, value: "exact race input")

    let firstTask = Task { try await service.command(start) }
    await promptGate.waitUntilEntered()
    // This is the public duplicate while the first caller is still suspended in prompt assembly.
    let duplicateTask = Task { try await service.command(start) }
    await promptGate.release()
    await hostedGate.waitUntilEntered()

    // Hosted has opened the exact Run and appended run.started, but the first command has not
    // yet accepted. A newer C1 cursor with the old command/body must not join the C0 task.
    let workData = try Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work))
    let workRead = TimelineJournalReader.read(
        workData, journal: created.work.journal,
        actor: TimelineActor(actorID: "journal-service-race-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let current = try XCTUnwrap(workRead.records.last?.event)
    let newerCursor = JournalCursor(
        journal: created.work.journal, eventID: current.eventID, sequence: current.sequence)
    let newerStart = WorkServiceCommandRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, commandID: "race-start", client: client,
        sessionAttachment: created.sessionAttachment, causalWorkCursor: newerCursor,
        kind: .start, value: "exact race input")
    do {
        _ = try await service.command(newerStart)
        XCTFail("a same body/ID with the post-run.started cursor must not join C0")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    } catch WorkServiceProtocolError.staleCursor {
        // The exact C0 duplicate may have durably accepted while Hosted was still held at its
        // preparation gate. In that ordering C1 is rejected by the prior command's immutable
        // causal cursor rather than the active-Run recovery fence; it still must not join.
        XCTAssertTrue(true)
    } catch {
        throw error
    }

    await hostedGate.release()
    let first: WorkServiceCommandReceipt
    do {
        first = try await firstTask.value
    } catch {
        XCTFail("exact concurrent Start owner failed: \(error)")
        await service.controlJournal.close()
        return
    }
    let duplicate: WorkServiceCommandReceipt
    do {
        duplicate = try await duplicateTask.value
    } catch {
        XCTFail("exact concurrent Start duplicate failed: \(error)")
        await service.controlJournal.close()
        return
    }
    XCTAssertEqual([first.state, duplicate.state].sorted { $0.rawValue < $1.rawValue },
                   [.accepted, .duplicate])
    XCTAssertEqual(first.causalWorkCursor, duplicate.causalWorkCursor)
    XCTAssertEqual(first.resultingWorkCursor, duplicate.resultingWorkCursor)
    XCTAssertEqual(first.hostSequence, duplicate.hostSequence)
    XCTAssertEqual(first.work, duplicate.work)
    XCTAssertEqual(first.commandID, duplicate.commandID)
    XCTAssertEqual(first.host, duplicate.host)
    XCTAssertEqual(first.hostProvenance, duplicate.hostProvenance)
    XCTAssertEqual(first.authorization, duplicate.authorization)
    XCTAssertEqual(first.outcome, duplicate.outcome)
    XCTAssertEqual(first.rejection, duplicate.rejection)
    XCTAssertEqual(first.recoveryState, duplicate.recoveryState)
    XCTAssertEqual(first.terminalProof, duplicate.terminalProof)
    XCTAssertEqual(first.diagnostic, duplicate.diagnostic)
    XCTAssertEqual(await promptGate.entries, 1)

    var ready = false
    let readyDeadline = Date().addingTimeInterval(10)
    while Date() < readyDeadline {
        let descriptor = try await service.describeWork(WorkServiceDescribeRequest(
            work: created.work.work, journal: created.work.journal, client: client))
        if descriptor.hostObservation?.reachability == .observedReachable {
            ready = true
            break
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(ready, "exact concurrent Start must finish Hosted preparation before cleanup")
    // Hosted may append its first-turn events between a cursor read and the End command.
    // Retry only this cleanup command on the resulting stale cursor; no Start admission is
    // retried, so the proof above remains a single-admission assertion.
    func latestWorkCursor() throws -> JournalCursor {
        let data = try Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work))
        let latestEvent = try XCTUnwrap(TimelineJournalReader.read(
            data,
            journal: created.work.journal,
            actor: TimelineActor(actorID: "journal-service-race-end-reader", kind: "self-test"),
            hostRecordedAt: Date(timeIntervalSince1970: 0)).records.last?.event)
        return JournalCursor(
            journal: created.work.journal, eventID: latestEvent.eventID,
            sequence: latestEvent.sequence)
    }
    var end: WorkServiceCommandReceipt?
    var endFailure: Error?
    for attempt in 0..<8 {
        let endCursor = try latestWorkCursor()
        do {
            end = try await service.command(WorkServiceCommandRequest(
                work: created.work.work, journal: created.work.journal,
                attachment: created.attachment.attachment, commandID: "race-end", client: client,
                sessionAttachment: created.sessionAttachment, causalWorkCursor: endCursor,
                kind: .end))
            break
        } catch WorkServiceProtocolError.staleCursor where attempt < 7 {
            try await Task.sleep(nanoseconds: 20_000_000)
        } catch {
            endFailure = error
            break
        }
    }
    if let endFailure {
        XCTFail("exact concurrent Start cleanup End failed: \(endFailure)")
        await service.controlJournal.close()
        return
    }
    guard let end else {
        XCTFail("exact concurrent Start cleanup End did not produce a receipt")
        await service.controlJournal.close()
        return
    }
    XCTAssertEqual(end.state, .accepted)
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceRejectsSameFlatDifferentPromptSources() async throws {
    guard let runtimeHost = try makeHost(.reference) else { return }
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try home.requirePersistedWorkHost()
    let client = ClientRef("assembly-client")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control, .start]
    let retainedAssembly = try journalServiceRaceAssembly()
    let differentAssembly = try SystemPromptAssembly(
        text: retainedAssembly.flattenedText,
        sources: [try PromptSource(
            sourceID: "different-source", kind: .generated,
            label: "different source", fullBody: retainedAssembly.flattenedText,
            deliveredBody: retainedAssembly.flattenedText,
            renderedBody: retainedAssembly.flattenedText)])
    let draftResolver: DurableJournalBackedWorkLaunchManifestStore.DraftResolver = { request in
        WorkLaunchManifestDraft(
            workspace: WorkLaunchWorkspace(locator: "/tmp", policy: .temporary),
            runtime: WorkLaunchRuntime(
                providerID: "test-provider", modelID: "test-model", runtimeVariant: "python3"),
            configuration: request.configuration,
            requestedCapabilities: request.requestedCapabilities,
            provenance: WorkLaunchManifestProvenance(source: "assembly-attestation"))
    }
    let hostedResolver: DurableJournalBackedWorkLaunchManifestStore.HostedConfigurationResolver = {
        _, binding, policy in
        var model = fakeModel()
        model.providerID = "test-provider"
        return HostedInHouseWorkConfiguration(
            home: home, cwd: "/tmp", model: model,
            provider: JournalServiceRaceProvider(), runtimeHost: runtimeHost,
            workRunBinding: binding, serviceActorID: "assembly-attestation",
            systemPrompt: differentAssembly.flattenedText,
            systemPromptAssembly: differentAssembly,
            projectionMode: policy.projection, modelContextMode: policy.modelContext)
    }
    let durable = DurableJournalBackedWorkLaunchManifestStore(
        store: WorkLaunchManifestStore(home: home), bodyAuthority: .workHost(host),
        draftResolver: draftResolver, hostedResolver: hostedResolver,
        promptAssemblyResolver: { _, _, _ in retainedAssembly },
        reconstructabilityProbe: { _ in true })
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: capabilities]),
        manifestStore: durable)
    let control = try await service.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "assembly-create", causalControlCursor: control,
        configuration: WorkServiceWorkConfiguration(
            providerID: "test-provider", modelID: "test-model"), requestedCapabilities: capabilities))
    do {
        _ = try await service.command(WorkServiceCommandRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, commandID: "assembly-start", client: client,
            sessionAttachment: created.sessionAttachment, causalWorkCursor: created.workCursor,
            kind: .start, value: "assembly input"))
        XCTFail("same flat prompt bytes with different source decomposition must fail closed")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceCreatesCanonicalPairAndReconstructsLostResponse() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = ClientRef("creator")
    let viewer = ClientRef("viewer")
    let grants = journalBackedAllCapabilities()
    let store = JournalBackedTestManifestStore(productionCapable: true)
    let service = try JournalBackedWorkService(
        home: home,
        instanceID: "instance-a",
        startIdentity: "start-a",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [creator: grants, viewer: grants]),
        manifestStore: store)
    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: creator)).controlCursor
    let request = WorkServiceCreateWorkRequest(
        client: creator, commandID: "create-1", causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control])
    let created = try await service.createWork(request)
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: home.timelineV2WorkJournalURL(created.work.work).path))
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: home.timelineV2SessionJournalURL(created.session).path))
    XCTAssertEqual(created.work.recordedDisposition, .reusable)
    XCTAssertEqual(created.work.execution, .idle)
    XCTAssertEqual(created.workCursor.sequence, 2)
    XCTAssertEqual(created.sessionCursor.sequence, 2)
    let controlEventsAfterCreate = try await service.controlJournal.read().records.count

    // A lost response retry uses the durable reservation, registration, and attachment.  It
    // must not mint another Work or another client attachment.
    let retried = try await service.createWork(request)
    XCTAssertEqual(retried.work.work, created.work.work)
    XCTAssertEqual(retried.attachment.attachment, created.attachment.attachment)
    XCTAssertEqual(retried.workCursor, created.workCursor)
    XCTAssertEqual(try await service.controlJournal.read().records.count,
                   controlEventsAfterCreate)

    let attached = try await service.attach(WorkServiceAttachRequest(
        work: created.work.work, journal: created.work.journal, client: viewer,
        commandID: "attach-viewer", causalControlCursor: created.controlCursor,
        requestedCapabilities: [.observe]))
    let viewerAttachment = try XCTUnwrap(attached.attachment)
    XCTAssertNotEqual(viewerAttachment.attachment, created.attachment.attachment)
    let described = try await service.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: viewer))
    XCTAssertEqual(described.attachments.count, 2)

    let events = try await service.eventsAfterCursor(WorkServiceEventsRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: viewerAttachment.attachment, client: viewer,
        target: .work(journal: created.work.journal),
        afterCursor: JournalCursor(journal: created.work.journal, sequence: 0), limit: 8))
    XCTAssertEqual(events.events.count, 2)
    XCTAssertEqual(events.servedCursor, created.workCursor)
    do {
        _ = try await service.eventsAfterCursor(WorkServiceEventsRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: viewerAttachment.attachment, client: viewer,
            target: .work(journal: created.work.journal),
            afterCursor: JournalCursor(
                journal: created.work.journal, eventID: "fabricated", sequence: 0), limit: 8))
        XCTFail("sequence-zero cursors with an event ID must not be treated as empty prefixes")
    } catch WorkServiceProtocolError.staleCursor {
        XCTAssertTrue(true)
    }

    let detached = try await service.detach(WorkServiceDetachRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: creator,
        commandID: "detach-creator", causalControlCursor: attached.resultingControlCursor))
    XCTAssertEqual(detached.state, .accepted)
    let afterDetach = try await service.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: viewer))
    XCTAssertEqual(afterDetach.attachments.count, 1)
    XCTAssertEqual(afterDetach.attachments[0].client, viewer)

    // Restart with the same durable-resolution seam. Canonical journals and the many-to-many
    // control attachment projection remain readable, while the recovery scanner recognizes an
    // idle reconstructable Work without manufacturing a live Hosted actor.
    await service.controlJournal.close()
    let restarted = try JournalBackedWorkService(
        home: home,
        instanceID: "instance-b",
        startIdentity: "start-b",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [creator: grants, viewer: grants]),
        manifestStore: store)
    let retriedAfterRestart = try await restarted.createWork(request)
    XCTAssertEqual(retriedAfterRestart.work.work, created.work.work)
    XCTAssertEqual(retriedAfterRestart.attachment.attachment, created.attachment.attachment)
    XCTAssertEqual(retriedAfterRestart.workCursor, created.workCursor)
    let reconstructed = try await restarted.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: viewer))
    XCTAssertEqual(reconstructed.work, created.work.work)
    XCTAssertEqual(reconstructed.attachments.count, 1)
    XCTAssertEqual(reconstructed.attachments[0].client, viewer)
    let recovery = try await restarted.scanRecovery()
    XCTAssertEqual(recovery.count, 1)
    XCTAssertEqual(recovery[0].disposition, .idleReconstructable)
    await restarted.controlJournal.close()
}

func testJournalBackedWorkServiceReconcilesExactControlMutationRetries() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = ClientRef("creator")
    let viewer = ClientRef("viewer")
    let service = try JournalBackedWorkService(
        home: home,
        instanceID: "instance-control-retry",
        startIdentity: "start-control-retry",
        authorizer: JournalBackedSameGrantAuthorizer(),
        manifestStore: JournalBackedTestManifestStore(productionCapable: true))
    defer { Task { await service.controlJournal.close() } }

    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: creator)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "create-control-retry", causalControlCursor: initial,
        requestedCapabilities: [.observe, .control]))
    let afterCreate = created.controlCursor
    let controlEventsBeforeMutations = try await service.controlJournal.read().records.count

    let attachRequest = WorkServiceAttachRequest(
        work: created.work.work, journal: created.work.journal, client: viewer,
        commandID: "attach-control-retry", causalControlCursor: afterCreate,
        requestedCapabilities: [.observe, .control])
    let attached = try await service.attach(attachRequest)
    XCTAssertEqual(attached.state, .accepted)
    XCTAssertEqual(attached.receipt.outcome, .attached)
    let viewerAttachment = try XCTUnwrap(attached.attachment)
    let attachDuplicate = try await service.attach(attachRequest)
    XCTAssertEqual(attachDuplicate.state, .duplicate)
    XCTAssertEqual(attachDuplicate.receipt.outcome, .attached)
    XCTAssertEqual(attachDuplicate.resultingControlCursor, attached.resultingControlCursor)
    XCTAssertEqual(attachDuplicate.attachment, attached.attachment)
    do {
        _ = try await service.attach(WorkServiceAttachRequest(
            work: attachRequest.work, journal: attachRequest.journal, client: viewer,
            commandID: attachRequest.commandID,
            causalControlCursor: attachRequest.causalControlCursor,
            requestedCapabilities: [.observe]))
        XCTFail("an attach request with a changed capability envelope reused its command")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }

    let updateRequest = WorkServiceUpdateCapabilitiesRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: viewerAttachment.attachment, client: viewer,
        requestedCapabilities: [.observe], commandID: "update-control-retry",
        causalControlCursor: attached.resultingControlCursor)
    let updated = try await service.updateCapabilities(updateRequest)
    XCTAssertEqual(updated.state, .accepted)
    let updateDuplicate = try await service.updateCapabilities(updateRequest)
    XCTAssertEqual(updateDuplicate.state, .duplicate)
    XCTAssertEqual(updateDuplicate.resultingControlCursor, updated.resultingControlCursor)
    XCTAssertEqual(updateDuplicate.attachment, updated.attachment)
    do {
        _ = try await service.updateCapabilities(WorkServiceUpdateCapabilitiesRequest(
            work: updateRequest.work, journal: updateRequest.journal,
            attachment: updateRequest.attachment, client: viewer,
            // Both envelopes reduce to the same granted set under this authorizer. Exact
            // requested-envelope binding, rather than the reduced grant, must still classify
            // this as a conflict.
            requestedCapabilities: [.observe, .start], commandID: updateRequest.commandID,
            causalControlCursor: updateRequest.causalControlCursor))
        XCTFail("an update request with a changed capability envelope reused its command")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }

    let acknowledgedTarget = WorkServiceReadTarget.work(journal: created.work.journal)
    let acknowledgeRequest = WorkServiceAcknowledgeReadRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment,
        client: creator, target: acknowledgedTarget, cursor: created.workCursor,
        commandID: "ack-control-retry", causalControlCursor: updated.resultingControlCursor)
    let acknowledged = try await service.acknowledgeRead(acknowledgeRequest)
    XCTAssertEqual(acknowledged.state, .accepted)
    let acknowledgeDuplicate = try await service.acknowledgeRead(acknowledgeRequest)
    XCTAssertEqual(acknowledgeDuplicate.state, .duplicate)
    XCTAssertEqual(acknowledgeDuplicate.resultingControlCursor,
                   acknowledged.resultingControlCursor)
    do {
        _ = try await service.acknowledgeRead(WorkServiceAcknowledgeReadRequest(
            work: acknowledgeRequest.work, journal: acknowledgeRequest.journal,
            attachment: acknowledgeRequest.attachment, client: creator,
            target: .session(session: created.session, journal: created.sessionJournal),
            cursor: created.sessionCursor, commandID: acknowledgeRequest.commandID,
            causalControlCursor: acknowledgeRequest.causalControlCursor))
        XCTFail("a read acknowledgement with a changed target reused its command")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }

    let detachRequest = WorkServiceDetachRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: creator,
        commandID: "detach-control-retry",
        causalControlCursor: acknowledged.resultingControlCursor)
    let detached = try await service.detach(detachRequest)
    XCTAssertEqual(detached.state, .accepted)
    let detachDuplicate = try await service.detach(detachRequest)
    XCTAssertEqual(detachDuplicate.state, .duplicate)
    XCTAssertEqual(detachDuplicate.resultingControlCursor, detached.resultingControlCursor)
    do {
        _ = try await service.detach(WorkServiceDetachRequest(
            work: detachRequest.work, journal: detachRequest.journal,
            attachment: ClientAttachmentRef("foreign-attachment"), client: creator,
            commandID: detachRequest.commandID,
            causalControlCursor: detachRequest.causalControlCursor))
        XCTFail("a detach request with a changed attachment reused its command")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }

    let records = try await service.controlJournal.read()
    // Each accepted mutation appends one event. Every exact retry and every changed-envelope
    // conflict is reconciliation-only, so the control prefix grows by exactly four records.
    XCTAssertEqual(records.records.count, controlEventsBeforeMutations + 4)
    XCTAssertNil(records.quarantinedSuffix)
    XCTAssertNil(records.truncatedTail)
    await service.controlJournal.close()
}

func testJournalBackedWorkServicePublishesCreateSessionAndReopensItsEvidence() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = ClientRef("session-creator")
    let viewer = ClientRef("session-viewer")
    let grants = journalBackedAllCapabilities()
    let store = JournalBackedTestManifestStore(productionCapable: true)
    let authorizer = WorkServiceCapabilityPolicy(
        grantsByClient: [creator: grants, viewer: grants])
    let service = try JournalBackedWorkService(
        home: home, instanceID: "session-instance-a", startIdentity: "session-start-a",
        authorizer: authorizer, manifestStore: store)
    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: creator)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "session-create-work", causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .createSession, .send]))
    let request = WorkServiceCreateSessionRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: creator,
        commandID: "session-create", causalControlCursor: created.controlCursor,
        causalWorkCursor: created.workCursor, requestedCapabilities: [.observe, .send])

    let first: WorkServiceCreateSessionResponse
    first = try await service.createSession(request)
    XCTAssertEqual(first.state, .accepted)
    XCTAssertEqual(first.receipt.operation, .createSession)
    XCTAssertEqual(first.receipt.outcome, .sessionCreated)
    XCTAssertEqual(first.controlCursor.sequence, created.controlCursor.sequence + 2)
    XCTAssertEqual(first.workCursor.sequence, created.workCursor.sequence + 1)
    let session = try XCTUnwrap(first.session)
    let sessionJournal = try XCTUnwrap(first.sessionJournal)
    let sessionAttachment = try XCTUnwrap(first.sessionAttachment)
    _ = try XCTUnwrap(first.attachment)
    let relationship = try XCTUnwrap(first.relationship)
    XCTAssertEqual(relationship.publication, .mirrored)
    XCTAssertEqual(relationship.session, session)
    XCTAssertEqual(relationship.sessionJournal, sessionJournal)
    XCTAssertEqual(relationship.sessionAttachment, sessionAttachment)
    XCTAssertEqual(relationship.causalWorkCursor, created.workCursor)
    XCTAssertEqual(relationship.resultingWorkCursor, first.workCursor)
    XCTAssertEqual(first.work.sessionAttachments.filter { $0.session == session }.count, 1)

    let controlEventsAfterFirst = try await service.controlJournal.read().records.count
    let duplicate = try await service.createSession(request)
    XCTAssertEqual(duplicate.state, .duplicate)
    XCTAssertEqual(duplicate.session, first.session)
    XCTAssertEqual(duplicate.attachment, first.attachment)
    XCTAssertEqual(duplicate.relationship, first.relationship)
    XCTAssertEqual(duplicate.controlCursor, first.controlCursor)
    XCTAssertEqual(try await service.controlJournal.read().records.count,
                   controlEventsAfterFirst)

    let second = try await service.createSession(WorkServiceCreateSessionRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: creator,
        commandID: "session-create-after-first", causalControlCursor: first.controlCursor,
        causalWorkCursor: first.workCursor, requestedCapabilities: [.observe]))
    XCTAssertEqual(second.state, .accepted)
    XCTAssertEqual(second.workCursor.sequence, first.workCursor.sequence + 1)
    let controlEventsAfterSecond = try await service.controlJournal.read().records.count
    let advancedDuplicate = try await service.createSession(request)
    XCTAssertEqual(advancedDuplicate.state, .duplicate)
    XCTAssertEqual(advancedDuplicate.session, first.session)
    XCTAssertEqual(advancedDuplicate.attachment, first.attachment)
    XCTAssertEqual(advancedDuplicate.relationship, first.relationship)
    XCTAssertEqual(advancedDuplicate.controlCursor, first.controlCursor)
    XCTAssertEqual(advancedDuplicate.workCursor, first.workCursor)
    XCTAssertEqual(try await service.controlJournal.read().records.count,
                   controlEventsAfterSecond)

    let attached = try await service.attach(WorkServiceAttachRequest(
        work: created.work.work, journal: created.work.journal, client: viewer,
        session: session, sessionJournal: sessionJournal,
        sessionAttachment: sessionAttachment, commandID: "session-viewer-attach",
        causalControlCursor: second.controlCursor, requestedCapabilities: [.observe]))
    let viewerAttachment = try XCTUnwrap(attached.attachment)
    let sessionPage = try await service.snapshot(WorkServiceSnapshotRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: viewerAttachment.attachment, client: viewer,
        target: .session(session: session, journal: sessionJournal), afterCursor: nil,
        limit: 8))
    XCTAssertEqual(sessionPage.events.map(\.type), [
        TimelineEventType.sessionCreated, TimelineEventType.sessionAttached,
        TimelineEventType.sessionAttachmentCursorAdvanced,
    ])
    XCTAssertEqual(sessionPage.servedCursor, first.sessionCursor)

    await service.controlJournal.close()
    let restarted = try JournalBackedWorkService(
        home: home, instanceID: "session-instance-b", startIdentity: "session-start-b",
        authorizer: authorizer, manifestStore: store)
    // Rehydrate the exact idle Work template before projecting a response after restart.
    _ = try await restarted.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "session-create-work", causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .createSession, .send]))
    let reopened = try await restarted.createSession(request)
    XCTAssertEqual(reopened.state, .duplicate)
    XCTAssertEqual(reopened.session, first.session)
    XCTAssertEqual(reopened.sessionCursor, first.sessionCursor)
    XCTAssertEqual(reopened.workCursor, first.workCursor)
    let reopenedDescriptor = try await restarted.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: creator))
    XCTAssertEqual(reopenedDescriptor.sessionAttachments.filter { $0.session == session }.count, 1)
    await restarted.controlJournal.close()
}

func testJournalBackedWorkServiceSessionAndClientBoundsPreserveExactRetry() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = ClientRef("bounded-session-creator")
    let grants = journalBackedAllCapabilities()
    let service = try JournalBackedWorkService(
        home: home, instanceID: "bounded-session-instance",
        startIdentity: "bounded-session-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [creator: grants]),
        manifestStore: JournalBackedTestManifestStore(productionCapable: true))
    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: creator)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "bounded-create-work", causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .createSession]))

    var controlCursor = created.controlCursor
    var workCursor = created.workCursor
    var finalRequest: WorkServiceCreateSessionRequest?
    var finalResponse: WorkServiceCreateSessionResponse?
    // Create carries one primary Session/client attachment. Fill the remaining semantic and
    // client attachment slots through the production durable saga.
    for index in 1..<WorkServiceBounds.maxSessionAttachmentsPerWork {
        let request = WorkServiceCreateSessionRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: creator,
            commandID: "bounded-create-session-\(index)",
            causalControlCursor: controlCursor, causalWorkCursor: workCursor,
            requestedCapabilities: [.observe])
        let response = try await service.createSession(request)
        XCTAssertEqual(response.state, .accepted)
        controlCursor = response.controlCursor
        workCursor = response.workCursor
        finalRequest = request
        finalResponse = response
    }

    let exactRequest = try XCTUnwrap(finalRequest)
    let exactResponse = try XCTUnwrap(finalResponse)
    let duplicate = try await service.createSession(exactRequest)
    XCTAssertEqual(duplicate.state, .duplicate)
    XCTAssertEqual(duplicate.session, exactResponse.session)
    XCTAssertEqual(duplicate.sessionAttachment, exactResponse.sessionAttachment)
    XCTAssertEqual(duplicate.attachment, exactResponse.attachment)
    XCTAssertEqual(duplicate.controlCursor, exactResponse.controlCursor)
    XCTAssertEqual(duplicate.workCursor, exactResponse.workCursor)

    let controlEventsBeforeRejections = try await service.controlJournal.read().records.count
    let workBytesBeforeRejections = try Data(
        contentsOf: home.timelineV2WorkJournalURL(created.work.work))
    do {
        _ = try await service.createSession(WorkServiceCreateSessionRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: creator,
            commandID: "bounded-create-session-overflow",
            causalControlCursor: controlCursor, causalWorkCursor: workCursor,
            requestedCapabilities: [.observe]))
        XCTFail("a new Session crossed the durable Work relationship/client attachment bound")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }
    do {
        _ = try await service.attach(WorkServiceAttachRequest(
            work: created.work.work, journal: created.work.journal,
            client: creator, commandID: "bounded-client-attach-overflow",
            causalControlCursor: controlCursor,
            requestedCapabilities: [.observe]))
        XCTFail("a new client attachment crossed the durable Work attachment bound")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(try await service.controlJournal.read().records.count,
                   controlEventsBeforeRejections)
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work)),
                   workBytesBeforeRejections)
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceTerminalSessionRequiresObserveBeforePublication() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = ClientRef("terminal-session-creator")
    let grants = journalBackedAllCapabilities()
    let service = try JournalBackedWorkService(
        home: home, instanceID: "terminal-session-instance",
        startIdentity: "terminal-session-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [creator: grants]),
        manifestStore: JournalBackedTestManifestStore(productionCapable: true))
    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: creator)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "terminal-session-create-work",
        causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .createSession]))
    let binding = WorkBinding(
        session: created.session, work: created.work.work,
        workHost: WorkHostRef(created.work.work.workHostID),
        sessionAttachment: created.sessionAttachment)
    let runBinding = WorkRunBinding(
        workBinding: binding, run: RunRef("terminal-session-run"))
    let execution = try await RunJournalBundle.openForExecution(
        home: home, binding: runBinding, actorID: "terminal-session-execution")
    _ = try await execution.finishRun(outcome: .completed)
    let finishedCursor = try XCTUnwrap(await execution.latestWorkCursor)
    try await execution.closeChecked()
    let terminal = try await RunJournalBundle.openForTerminalMutation(
        home: home, binding: runBinding,
        actorID: "terminal-session-committer")
    let terminalCommand = CommandRef(
        commandID: "terminal-session-complete", client: creator,
        sessionAttachment: created.sessionAttachment, causalCursor: finishedCursor)
    let terminalCommits = try await terminal.completeWork(
        detail: "complete before Session reference", command: terminalCommand)
    try await terminal.closeChecked()
    let terminalWorkCursor = terminalCommits[0].cursor
    let controlEventsBefore = try await service.controlJournal.read().records.count
    let sessionFilesBefore = try FileManager.default.contentsOfDirectory(
        at: home.timelineV2SessionsDir,
        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count
    let workBytesBefore = try Data(
        contentsOf: home.timelineV2WorkJournalURL(created.work.work))

    do {
        _ = try await service.createSession(WorkServiceCreateSessionRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: creator,
            commandID: "terminal-session-without-observe",
            causalControlCursor: created.controlCursor,
            causalWorkCursor: terminalWorkCursor,
            requestedCapabilities: [.send]))
        XCTFail("terminal Session publication accepted without an effective observe grant")
    } catch WorkServiceProtocolError.capabilityDenied(.observe) {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(try await service.controlJournal.read().records.count,
                   controlEventsBefore)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(
        at: home.timelineV2SessionsDir,
        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count,
        sessionFilesBefore)
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work)),
                   workBytesBefore)
    await service.controlJournal.close()
}

func testJournalBackedWorkServicePublishesTerminalSessionReferenceAndReopens() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = ClientRef("terminal-reference-creator")
    let viewer = ClientRef("terminal-reference-viewer")
    let grants = journalBackedAllCapabilities()
    let store = JournalBackedTestManifestStore(productionCapable: true)
    let authorizer = WorkServiceCapabilityPolicy(grantsByClient: [
        creator: grants, viewer: [.observe],
    ])
    let service = try JournalBackedWorkService(
        home: home, instanceID: "terminal-reference-instance-a",
        startIdentity: "terminal-reference-start-a",
        authorizer: authorizer, manifestStore: store)
    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: creator)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "terminal-reference-create-work",
        causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .createSession]))
    let binding = WorkBinding(
        session: created.session, work: created.work.work,
        workHost: WorkHostRef(created.work.work.workHostID),
        sessionAttachment: created.sessionAttachment)
    let runBinding = WorkRunBinding(
        workBinding: binding, run: RunRef("terminal-reference-run"))
    let execution = try await RunJournalBundle.openForExecution(
        home: home, binding: runBinding, actorID: "terminal-reference-execution")
    _ = try await execution.finishRun(outcome: .completed)
    let finishedCursor = try XCTUnwrap(await execution.latestWorkCursor)
    try await execution.closeChecked()
    let terminal = try await RunJournalBundle.openForTerminalMutation(
        home: home, binding: runBinding, actorID: "terminal-reference-committer")
    let terminalCommand = CommandRef(
        commandID: "terminal-reference-complete", client: creator,
        sessionAttachment: created.sessionAttachment, causalCursor: finishedCursor)
    let terminalCommits = try await terminal.completeWork(
        detail: "immutable completed Work", command: terminalCommand)
    try await terminal.closeChecked()
    let terminalWorkCursor = terminalCommits[0].cursor
    let workBytesBeforeReference = try Data(
        contentsOf: home.timelineV2WorkJournalURL(created.work.work))
    let request = WorkServiceCreateSessionRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: creator,
        commandID: "terminal-reference-create-session",
        causalControlCursor: created.controlCursor,
        causalWorkCursor: terminalWorkCursor,
        requestedCapabilities: [.observe])
    let referenced = try await service.createSession(request)
    XCTAssertEqual(referenced.state, .accepted)
    XCTAssertEqual(referenced.relationship?.publication, .terminalReference)
    XCTAssertEqual(referenced.authorization.granted, [.observe])
    XCTAssertEqual(referenced.workCursor, terminalWorkCursor)
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work)),
                   workBytesBeforeReference)
    let referencedSession = try XCTUnwrap(referenced.session)
    let referencedJournal = try XCTUnwrap(referenced.sessionJournal)
    let referencedAttachment = try XCTUnwrap(referenced.sessionAttachment)
    let sessionRead = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2SessionJournalURL(referencedSession)),
        journal: referencedJournal,
        actor: TimelineActor(actorID: "terminal-reference-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(sessionRead.records.map(\.event.type), [
        TimelineEventType.sessionCreated, TimelineEventType.sessionAttached,
        TimelineEventType.sessionAttachmentCursorAdvanced,
    ])
    XCTAssertEqual(sessionRead.records.last?.event.causedByEventID,
                   terminalCommits[0].eventRef)

    let attached = try await service.attach(WorkServiceAttachRequest(
        work: created.work.work, journal: created.work.journal, client: viewer,
        session: referencedSession, sessionJournal: referencedJournal,
        sessionAttachment: referencedAttachment,
        commandID: "terminal-reference-viewer-attach",
        causalControlCursor: referenced.controlCursor,
        requestedCapabilities: [.observe]))
    let viewerAttachment = try XCTUnwrap(attached.attachment)
    let workPage = try await service.snapshot(WorkServiceSnapshotRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: viewerAttachment.attachment, client: viewer,
        target: .work(journal: created.work.journal), afterCursor: nil,
        limit: WorkServiceBounds.maxEventsPerPage))
    XCTAssertEqual(workPage.servedCursor, terminalWorkCursor)
    XCTAssertEqual(workPage.events.last?.type, TimelineEventType.workCompleted)
    XCTAssertFalse(workPage.events.contains {
        $0.sessionAttachment == referencedAttachment
            && $0.type == TimelineEventType.sessionAttached
    })

    await service.controlJournal.close()
    let restarted = try JournalBackedWorkService(
        home: home, instanceID: "terminal-reference-instance-b",
        startIdentity: "terminal-reference-start-b",
        authorizer: authorizer, manifestStore: store)
    _ = try await restarted.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "terminal-reference-create-work",
        causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .createSession]))
    let reopened = try await restarted.createSession(request)
    XCTAssertEqual(reopened.state, .duplicate)
    XCTAssertEqual(reopened.session, referenced.session)
    XCTAssertEqual(reopened.relationship, referenced.relationship)
    XCTAssertEqual(reopened.workCursor, terminalWorkCursor)
    XCTAssertEqual(reopened.controlCursor, referenced.controlCursor)
    await restarted.controlJournal.close()
}

func testJournalBackedWorkServiceSecondarySessionDetachStaysDetachedAfterRestart() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let creator = ClientRef("secondary-detach-creator")
    let grants = journalBackedAllCapabilities()
    let store = JournalBackedTestManifestStore(productionCapable: true)
    let authorizer = WorkServiceCapabilityPolicy(grantsByClient: [creator: grants])
    let service = try JournalBackedWorkService(
        home: home, instanceID: "secondary-detach-instance-a",
        startIdentity: "secondary-detach-start-a",
        authorizer: authorizer, manifestStore: store)
    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: creator)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "secondary-detach-create-work",
        causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .createSession]))
    let secondary = try await service.createSession(WorkServiceCreateSessionRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: creator,
        commandID: "secondary-detach-create-session",
        causalControlCursor: created.controlCursor,
        causalWorkCursor: created.workCursor,
        requestedCapabilities: [.observe, .control]))
    let secondaryClientAttachment = try XCTUnwrap(secondary.attachment)
    let secondarySession = try XCTUnwrap(secondary.session)
    let secondaryJournal = try XCTUnwrap(secondary.sessionJournal)
    _ = try await service.snapshot(WorkServiceSnapshotRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: secondaryClientAttachment.attachment, client: creator,
        target: .session(session: secondarySession, journal: secondaryJournal)))

    let detached = try await service.detach(WorkServiceDetachRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: secondaryClientAttachment.attachment, client: creator,
        commandID: "secondary-detach", causalControlCursor: secondary.controlCursor))
    XCTAssertEqual(detached.state, .accepted)
    let afterDetach = try await service.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: creator))
    XCTAssertFalse(afterDetach.attachments.contains {
        $0.attachment == secondaryClientAttachment.attachment
    })
    do {
        _ = try await service.snapshot(WorkServiceSnapshotRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: secondaryClientAttachment.attachment, client: creator,
            target: .session(session: secondarySession, journal: secondaryJournal)))
        XCTFail("a detached secondary-Session client attachment remained authorized")
    } catch WorkServiceProtocolError.attachmentNotFound {
        XCTAssertTrue(true)
    }

    await service.controlJournal.close()
    let restarted = try JournalBackedWorkService(
        home: home, instanceID: "secondary-detach-instance-b",
        startIdentity: "secondary-detach-start-b",
        authorizer: authorizer, manifestStore: store)
    _ = try await restarted.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "secondary-detach-create-work",
        causalControlCursor: initial,
        configuration: WorkServiceWorkConfiguration(providerID: "provider", modelID: "model"),
        requestedCapabilities: [.observe, .control, .createSession]))
    let afterRestart = try await restarted.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: creator))
    XCTAssertFalse(afterRestart.attachments.contains {
        $0.attachment == secondaryClientAttachment.attachment
    })
    do {
        _ = try await restarted.snapshot(WorkServiceSnapshotRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: secondaryClientAttachment.attachment, client: creator,
            target: .session(session: secondarySession, journal: secondaryJournal)))
        XCTFail("restart resurrected a detached secondary-Session client attachment")
    } catch WorkServiceProtocolError.attachmentNotFound {
        XCTAssertTrue(true)
    }
    await restarted.controlJournal.close()
}

func testJournalBackedWorkServiceReadsLongWorkAndSessionJournalsThroughControllerPages() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("multipage-client")
    let grants = journalBackedAllCapabilities()
    let service = try JournalBackedWorkService(
        home: home,
        instanceID: "instance-multipage",
        startIdentity: "start-multipage",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]),
        manifestStore: JournalBackedTestManifestStore(productionCapable: true))
    let initial = try await service.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-multipage", causalControlCursor: initial,
        requestedCapabilities: [.observe, .control]))

    let sessionWriter = try TimelineJournalWriter(
        reopening: home.timelineV2SessionJournalURL(created.session),
        journal: created.sessionJournal,
        actor: TimelineActor(actorID: "multipage-writer", kind: "test"), home: home)
    for index in 0..<7 {
        _ = try await sessionWriter.append(TimelineEventDraft(
            session: created.session, work: created.work.work,
            workHost: WorkHostRef(created.work.work.workHostID),
            sessionAttachment: created.sessionAttachment,
            type: TimelineEventType.messageCommitted, declaredDomains: [.session],
            payload: .object([
                "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                "text": .string("multipage message \(index)")
            ])))
    }
    try await sessionWriter.closeChecked()

    let workPage = try await service.snapshot(WorkServiceSnapshotRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: client,
        target: .work(journal: created.work.journal),
        afterCursor: JournalCursor(journal: created.work.journal, sequence: 0),
        limit: 1))
    XCTAssertEqual(workPage.events.count, 1)
    XCTAssertEqual(workPage.servedCursor?.sequence, 1)
    XCTAssertEqual(workPage.omissions.map(\.category), ["events"])
    XCTAssertEqual(workPage.omissions.first?.count, 1)
    XCTAssertNotNil(workPage.basePrefixDigest)
    XCTAssertNotNil(workPage.prefixDigest)
    let workContinuation = try await service.eventsAfterCursor(WorkServiceEventsRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: client,
        target: .work(journal: created.work.journal),
        afterCursor: try XCTUnwrap(workPage.servedCursor), limit: 1))
    XCTAssertEqual(workContinuation.events.count, 1)
    XCTAssertEqual(workContinuation.servedCursor?.sequence, 2)
    XCTAssertNil(workContinuation.nextCursor)
    XCTAssertTrue(workContinuation.omissions.isEmpty)
    XCTAssertEqual(workContinuation.basePrefixDigest, workPage.prefixDigest)
    XCTAssertNotEqual(workContinuation.prefixDigest, workContinuation.basePrefixDigest)

    let sessionPage = try await service.snapshot(WorkServiceSnapshotRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: client,
        target: .session(session: created.session, journal: created.sessionJournal),
        afterCursor: JournalCursor(journal: created.sessionJournal, sequence: 0),
        limit: 1))
    XCTAssertEqual(sessionPage.events.count, 1)
    XCTAssertEqual(sessionPage.servedCursor?.sequence, 1)
    XCTAssertEqual(sessionPage.omissions.map(\.category), ["events"])
    XCTAssertEqual(sessionPage.omissions.first?.count, 8)
    XCTAssertNotNil(sessionPage.basePrefixDigest)
    XCTAssertNotEqual(sessionPage.basePrefixDigest, sessionPage.prefixDigest)
    let firstWorkRead = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(created.work.work)),
        journal: created.work.journal,
        actor: TimelineActor(actorID: "multipage-test-reader", kind: "test"),
        hostRecordedAt: Date())
    let firstTwoEventBytes = try firstWorkRead.records.prefix(2).map {
        try WorkServiceEventPageSizing.encodedByteCount(of: $0.event)
    }
    let firstEventPageBytes = try XCTUnwrap(firstTwoEventBytes.max())
    let byteBoundPage = try await service.snapshot(WorkServiceSnapshotRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: client,
        target: .work(journal: created.work.journal),
        afterCursor: JournalCursor(journal: created.work.journal, sequence: 0),
        limit: 8, maxBytes: firstEventPageBytes))
    XCTAssertEqual(byteBoundPage.events.count, 1)
    XCTAssertEqual(byteBoundPage.omissions.map(\.category), ["event_bytes"])
    XCTAssertEqual(byteBoundPage.omissions.first?.count, 1)

    let descriptor = try await service.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: client))
    let intentStore = try WorkServiceAttachedWorkIntentStore(
        home: home, client: client, work: created.work.work)
    let controller = try WorkServiceAttachedWorkController(
        service: service, seed: .existing(work: descriptor, attachment: created.attachment),
        intentStore: intentStore,
        pageLimit: 1)
    let projection = try await controller.refresh()

    XCTAssertTrue(projection.isCanonical)
    XCTAssertTrue(projection.projectionComplete)
    XCTAssertEqual(projection.workSourceCompleteness, .complete)
    XCTAssertEqual(projection.sessionSourceCompleteness, .complete)
    XCTAssertTrue(projection.workOmissions.isEmpty)
    XCTAssertTrue(projection.sessionOmissions.isEmpty)
    XCTAssertEqual(projection.workCursor.sequence, created.workCursor.sequence)
    XCTAssertEqual(projection.sessionCursor.sequence, created.sessionCursor.sequence + 7)
    XCTAssertEqual(projection.descriptor.work, descriptor.work)
    XCTAssertEqual(projection.descriptor.journal, descriptor.journal)
    XCTAssertEqual(projection.descriptor.recordedDisposition, descriptor.recordedDisposition)
    XCTAssertEqual(projection.descriptor.execution, descriptor.execution)
    XCTAssertEqual(projection.descriptor.currentRun, descriptor.currentRun)
    XCTAssertEqual(projection.descriptor.configuration, descriptor.configuration)
    XCTAssertEqual(projection.descriptor.hostObservation, descriptor.hostObservation)
    XCTAssertEqual(projection.descriptor.artifacts, descriptor.artifacts)
    XCTAssertEqual(projection.descriptor.omissions, descriptor.omissions)
    XCTAssertEqual(projection.descriptor.attachments, [projection.attachment])
    XCTAssertEqual(Set(projection.attachment.readAcknowledgements), Set([
        WorkServiceReadAcknowledgement(
            target: .work(journal: created.work.journal),
            cursor: projection.workCursor),
        WorkServiceReadAcknowledgement(
            target: .session(session: created.session, journal: created.sessionJournal),
            cursor: projection.sessionCursor),
    ]))
    XCTAssertEqual(projection.visibleMessages.count, 7)
    XCTAssertEqual(projection.visibleMessages.first?.text, "multipage message 0")
    XCTAssertEqual(projection.visibleMessages.last?.text, "multipage message 6")
    XCTAssertEqual(projection.workSnapshot.lifecycle, .active)
    XCTAssertEqual(projection.sessionSnapshot.lifecycle, .active)
    await service.controlJournal.close()
}

/// Exercise the nonresident source path without using a writer append for every record (which
/// would make this a test of fsync throughput rather than the reader). The journal remains a
/// normal canonical append chain; only the fixture construction batches its durable write.
func testJournalBackedWorkServiceKeepsOversizedJournalsReadableAndIncrementallyCached() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("oversized-client")
    let grants = journalBackedAllCapabilities()
    let service = try JournalBackedWorkService(
        home: home,
        instanceID: "instance-oversized",
        startIdentity: "start-oversized",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]),
        manifestStore: JournalBackedTestManifestStore(productionCapable: true))
    let control = try await service.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-oversized", causalControlCursor: control,
        requestedCapabilities: [.observe, .control]))
    let descriptor = try await service.describeWork(WorkServiceDescribeRequest(
        work: created.work.work, journal: created.work.journal, client: client))
    let before = await service.journalReadMetrics()

    let workURL = home.timelineV2WorkJournalURL(created.work.work)
    let initial = TimelineJournalReader.read(
        try Data(contentsOf: workURL), journal: created.work.journal,
        actor: TimelineActor(actorID: "oversized-fixture", kind: "test"), hostRecordedAt: Date())
    let lastInitial = try XCTUnwrap(initial.records.last?.event)
    let padding = String(repeating: "x", count: 8_192)
    let eventCount = 8_000
    let handle = try FileHandle(forWritingTo: workURL)
    try handle.seekToEnd()
    var previousID = lastInitial.eventID
    var finalSequence = lastInitial.sequence
    var finalID = lastInitial.eventID
    for offset in 0..<eventCount {
        let sequence = lastInitial.sequence + offset + 1
        let eventID = "oversized-\(sequence)"
        let event = TimelineEvent(
            eventID: eventID, journal: created.work.journal, sequence: sequence,
            previousEventID: previousID, work: created.work.work,
            workHost: WorkHostRef(created.work.work.workHostID),
            actor: TimelineActor(actorID: "oversized-fixture", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            type: TimelineEventType.modelChanged, declaredDomains: [.work],
            payload: .object(["model_id": .string("oversized"), "padding": .string(padding)]))
        var line = try JSONEncoder().encode(event)
        line.append(0x0A)
        try handle.write(contentsOf: line)
        previousID = eventID
        finalSequence = sequence
        finalID = eventID
    }
    try handle.synchronize()
    try handle.close()
    let oversizedBytes = try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: workURL.path)[.size] as? NSNumber).intValue
    XCTAssertTrue(oversizedBytes > 64 * 1024 * 1024)

    // A valid source larger than the former lifetime limit remains canonical. Its first page is
    // served from the sparse/indexed path and carries a checkpoint token despite no full event
    // array being retained in memory.
    let firstPage = try await service.snapshot(WorkServiceSnapshotRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: client,
        target: .work(journal: created.work.journal),
        afterCursor: JournalCursor(journal: created.work.journal, sequence: 0), limit: 1))
    XCTAssertEqual(firstPage.events.count, 1)
    XCTAssertNotNil(firstPage.basePrefixDigest)
    XCTAssertNotNil(firstPage.prefixDigest)
    let afterOversized = try await service.eventsAfterCursor(WorkServiceEventsRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: client,
        target: .work(journal: created.work.journal),
        afterCursor: JournalCursor(
            journal: created.work.journal, eventID: finalID, sequence: finalSequence),
        limit: 1))
    XCTAssertTrue(afterOversized.events.isEmpty)
    XCTAssertEqual(afterOversized.basePrefixDigest, afterOversized.prefixDigest)
    let scannedOversized = await service.journalReadMetrics()
    XCTAssertTrue(scannedOversized.bytesScanned > before.bytesScanned)
    // `describeWork` above cached the small genesis prefix. Growing that same canonical file past
    // the resident threshold is therefore an incremental scan which transitions the cache to its
    // sparse representation; it must not be mislabeled as a cold rebuild.
    XCTAssertTrue(scannedOversized.incrementalReads > before.incrementalReads)

    // The next descriptor/poll is a metadata/cache hit: no history bytes are scanned again.
    _ = try await service.describeWork(WorkServiceDescribeRequest(
        work: descriptor.work, journal: descriptor.journal, client: client))
    let hit = await service.journalReadMetrics()
    XCTAssertEqual(hit.bytesScanned, scannedOversized.bytesScanned)
    XCTAssertTrue(hit.cacheHits > scannedOversized.cacheHits)

    // Appending one event reuses the validated prefix and applies only the new suffix. The
    // resulting page can address that delta by its exact cursor.
    let deltaID = "oversized-delta-\(finalSequence + 1)"
    let deltaEvent = TimelineEvent(
        eventID: deltaID, journal: created.work.journal, sequence: finalSequence + 1,
        previousEventID: finalID, work: created.work.work,
        workHost: WorkHostRef(created.work.work.workHostID),
        actor: TimelineActor(actorID: "oversized-fixture", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(finalSequence + 1)),
        type: TimelineEventType.modelChanged, declaredDomains: [.work],
        payload: .object(["model_id": .string("oversized-delta")]))
    var deltaLine = try JSONEncoder().encode(deltaEvent)
    deltaLine.append(0x0A)
    let deltaHandle = try FileHandle(forWritingTo: workURL)
    try deltaHandle.seekToEnd()
    try deltaHandle.write(contentsOf: deltaLine)
    try deltaHandle.synchronize()
    try deltaHandle.close()
    _ = try await service.describeWork(WorkServiceDescribeRequest(
        work: descriptor.work, journal: descriptor.journal, client: client))
    let incremented = await service.journalReadMetrics()
    XCTAssertTrue(incremented.incrementalReads > hit.incrementalReads)
    XCTAssertTrue(incremented.bytesScanned - hit.bytesScanned < oversizedBytes / 2)
    let deltaPage = try await service.eventsAfterCursor(WorkServiceEventsRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: client,
        target: .work(journal: created.work.journal),
        afterCursor: JournalCursor(
            journal: created.work.journal, eventID: finalID, sequence: finalSequence), limit: 1))
    XCTAssertEqual(deltaPage.events.map(\.eventID), [deltaID])
    XCTAssertEqual(deltaPage.basePrefixDigest, afterOversized.basePrefixDigest)
    XCTAssertNotEqual(deltaPage.prefixDigest, deltaPage.basePrefixDigest)
    await service.controlJournal.close()
}

func testJournalBackedWorkServiceFailsClosedOnCorruptSource() async throws {
    let (home, root) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("creator")
    let grants = journalBackedAllCapabilities()
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]),
        manifestStore: JournalBackedTestManifestStore())
    let cursor = try await service.handshake(WorkServiceHandshakeRequest(client: client)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-corrupt", causalControlCursor: cursor))
    await service.controlJournal.close()
    let workURL = home.timelineV2WorkJournalURL(created.work.work)
    var data = try Data(contentsOf: workURL)
    data.append(Data("{}\n".utf8))
    try data.write(to: workURL)
    let reopened = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]),
        manifestStore: JournalBackedTestManifestStore())
    do {
        _ = try await reopened.describeWork(WorkServiceDescribeRequest(
            work: created.work.work, journal: created.work.journal, client: client))
        XCTFail("a malformed canonical suffix must not be served")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    let scan = try await reopened.scanRecovery()
    XCTAssertEqual(scan.first?.disposition, .corrupt)
    await reopened.controlJournal.close()

    // A well-formed event from a newer reducer is distinct from a malformed journal suffix. It
    // remains readable for inspection, but its declared Work domain makes execution unknown and
    // all mutations must fail closed rather than guessing that the reducer meant idle.
    let (unknownHome, unknownRoot) = try journalBackedHome()
    defer { try? FileManager.default.removeItem(at: unknownRoot) }
    let unknownService = try JournalBackedWorkService(
        home: unknownHome,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]),
        manifestStore: JournalBackedTestManifestStore(productionCapable: true))
    let unknownControlCursor = try await unknownService.handshake(
        WorkServiceHandshakeRequest(client: client)).controlCursor
    let unknownCreated = try await unknownService.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "create-unknown-reducer",
        causalControlCursor: unknownControlCursor, requestedCapabilities: grants))
    let unknownWriter = try TimelineJournalWriter(
        reopening: unknownHome.timelineV2WorkJournalURL(unknownCreated.work.work),
        journal: unknownCreated.work.journal,
        actor: TimelineActor(actorID: "future-reducer", kind: "future-reducer"),
        home: unknownHome)
    _ = try await unknownWriter.append(TimelineEventDraft(
        session: unknownCreated.session, work: unknownCreated.work.work,
        type: "work.execution-from-future", declaredDomains: [.work],
        payload: .object(["execution": .string("future-state")])))
    try await unknownWriter.closeChecked()
    // The Work Host control verifier deliberately refuses to call an unknown reducer state a
    // verified source. The service therefore exposes the row as unavailable (`sourceIncomplete`)
    // rather than guessing an execution state.
    do {
        _ = try await unknownService.describeWork(WorkServiceDescribeRequest(
            work: unknownCreated.work.work, journal: unknownCreated.work.journal, client: client))
        XCTFail("an unknown reducer state must not be served as a descriptor")
    } catch {
        XCTAssertEqual(error as? WorkServiceProtocolError, .sourceIncomplete)
    }
    let unknownRecovery = try await unknownService.scanRecovery()
    XCTAssertEqual(unknownRecovery.first?.disposition, .corrupt)
    for (kind, commandID) in [
        (WorkServiceCommandKind.start, "start-unknown-reducer"),
        (.complete, "complete-unknown-reducer"),
        (.destroy, "destroy-unknown-reducer"),
    ] {
        do {
            _ = try await unknownService.command(WorkServiceCommandRequest(
                work: unknownCreated.work.work, journal: unknownCreated.work.journal,
                attachment: unknownCreated.attachment.attachment, commandID: commandID,
                client: client, sessionAttachment: unknownCreated.sessionAttachment,
                causalWorkCursor: unknownCreated.workCursor, kind: kind,
                value: kind == .start ? "future" : nil))
            XCTFail("\(kind) must not act on an unknown reducer projection")
        } catch WorkServiceProtocolError.sourceIncomplete {
            XCTAssertTrue(true)
        }
    }
    await unknownService.controlJournal.close()
}

/// Creation is a two-file append sequence, so each writer-open/append failure leaves a valid
/// prefix (or a bounded partial tail). An exact unregistered reservation is continued under both
/// locks; the retry returns the same two-event pair without minting another identity.
func testJournalBackedWorkServiceContinuesEveryIdleGenesisPrefix() async throws {
    let failurePoints: [TimelineJournalWriter.FailurePoint] = [
        .beforeWrite, .partialWrite, .afterWriteBeforeSync, .sync,
        .close,
    ]
    for journal in [TimelineJournalKind.session, .work] {
        for point in failurePoints {
            let (home, root) = try journalBackedHome()
            defer { try? FileManager.default.removeItem(at: root) }
            let host = try home.requirePersistedWorkHost()
            let binding = WorkBinding(
                session: SessionRef("idle-prefix-session-\(journal.rawValue)-\(point.rawValue)"),
                work: WorkRef(workHostID: host.workHostID,
                              workID: "idle-prefix-work-\(journal.rawValue)-\(point.rawValue)"),
                workHost: host,
                sessionAttachment: SessionAttachmentRef("idle-prefix-attachment"))
            let failure: (session: TimelineJournalWriter.FailurePlan,
                          work: TimelineJournalWriter.FailurePlan) = journal == .session
                ? (.init(point: point), .none) : (.none, .init(point: point))
            do {
                _ = try await RunJournalBundle.createIdleWork(
                    home: home, binding: binding, actorID: "idle-prefix-test",
                    failurePlan: failure)
                XCTFail("injected \(journal.rawValue)/\(point.rawValue) failure was not observed")
            } catch {
                // The durable prefix is intentionally observable and is the retry input.
            }
            let retry = try await RunJournalBundle.createIdleWork(
                home: home, binding: binding, actorID: "idle-prefix-test")
            XCTAssertEqual(retry.binding, binding)
            XCTAssertEqual(retry.sessionCursor.sequence, 2)
            XCTAssertEqual(retry.workCursor.sequence, 2)
            XCTAssertEqual(retry.commits.count, 4)
        }
    }
}

/// The only valid one-sided creation state is an empty Session file opened before the Work
/// writer. Eventful Session-without-Work and Work-only files are impossible prefixes; rejecting
/// them before opening/creating the counterpart prevents a failed reservation from being
/// transformed into a different retry state.
func testJournalBackedWorkServiceRejectsImpossibleIdleGenesisPresenceStates() async throws {
    for impossible in ["session-event-without-work", "work-only"] {
        let (home, root) = try journalBackedHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try home.requirePersistedWorkHost()
        let binding = WorkBinding(
            session: SessionRef("presence-session-\(impossible)"),
            work: WorkRef(workHostID: host.workHostID, workID: "presence-work-\(impossible)"),
            workHost: host,
            sessionAttachment: SessionAttachmentRef("presence-attachment-\(impossible)"))
        let actor = TimelineActor(actorID: "presence-test", kind: "work-host-control")
        let sessionURL = home.timelineV2SessionJournalURL(binding.session)
        let workURL = home.timelineV2WorkJournalURL(binding.work)
        if impossible == "session-event-without-work" {
            let journal = JournalRef.session(
                binding.session, authority: TimelineAuthorityRef(host.workHostID))
            let writer = try TimelineJournalWriter(
                freshAt: sessionURL, journal: journal, actor: actor, home: home)
            _ = try await writer.append(TimelineEventDraft(
                hostSequence: 1, session: binding.session,
                type: TimelineEventType.sessionCreated, declaredDomains: [.session]))
            try await writer.closeChecked()
        } else {
            let writer = try TimelineJournalWriter(
                freshAt: workURL, journal: JournalRef.work(binding.work), actor: actor, home: home)
            try await writer.closeChecked()
        }
        do {
            _ = try await RunJournalBundle.createIdleWork(
                home: home, binding: binding, actorID: actor.actorID)
            XCTFail("impossible \(impossible) prefix was accepted")
        } catch RunJournalBundleError.invalidGenesis {
            XCTAssertTrue(true)
        }
        if impossible == "session-event-without-work" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: workURL.path))
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
        }
    }
}

/// Hosted construction is allowed to suspend, so the Work registry must reserve its slot before
/// opening an actor. These checks exercise the actor-isolated fence without manufacturing a
/// runtime: a reservation counts against capacity, blocks canonical/direct occupancy, and an
/// exact cancellation frees the slot for a concurrent admission.
func testJournalBackedWorkServiceRegistryReservationsAreBoundedAndFenced() async throws {
    let host = WorkHostRef("reservation-host")
    let registry = WorkHostRegistry(
        host: host,
        bounds: WorkHostRegistryBounds(
            maxEntries: 4, maxLiveEntries: 1, maxCanonicalEntries: 4))
    let first = WorkRef(workHostID: host.workHostID, workID: "reservation-first")
    let second = WorkRef(workHostID: host.workHostID, workID: "reservation-second")
    let metadata = WorkHostLaunchMetadata(
        providerID: "provider", modelID: "model", actorKind: "work-host")
    let reservation = try await registry.reserveRegistration(
        for: first, launchMetadata: metadata)
    XCTAssertEqual(reservation.work, first)
    XCTAssertEqual(reservation.launchMetadata, metadata)
    XCTAssertEqual(await registry.liveCount, 0)

    do {
        _ = try await registry.reserveRegistration(for: first)
        XCTFail("the same Work cannot be reserved twice")
    } catch WorkHostRegistryError.registrationConflict(first) {
        XCTAssertTrue(true)
    }
    do {
        try await registry.registerCanonical(WorkHostRegistryCanonicalFact(
            work: first, disposition: .recovering, sourceID: "reservation-canonical"))
        XCTFail("a reservation must fence canonical occupancy")
    } catch WorkHostRegistryError.registrationConflict(first) {
        XCTAssertTrue(true)
    }
    do {
        _ = try await registry.reserveRegistration(for: second)
        XCTFail("a reservation must count against live capacity")
    } catch WorkHostRegistryError.liveCapacityExceeded {
        XCTAssertTrue(true)
    }

    // A token minted by another registry is foreign even when it names the same Work.  It may
    // not cancel this registry's real reservation, so the live-capacity fence remains held.
    let foreignRegistry = WorkHostRegistry(
        host: host, instanceID: "reservation-foreign-instance",
        startIdentity: "reservation-foreign-start",
        bounds: WorkHostRegistryBounds(maxEntries: 4, maxLiveEntries: 1, maxCanonicalEntries: 4))
    let foreign = try await foreignRegistry.reserveRegistration(for: first)
    await registry.cancelRegistration(foreign)
    do {
        _ = try await registry.reserveRegistration(for: second)
        XCTFail("a foreign token must not cancel the real reservation")
    } catch WorkHostRegistryError.liveCapacityExceeded {
        XCTAssertTrue(true)
    }

    // A stale cancellation cannot release the real reservation either.
    do {
        _ = try await registry.reserveRegistration(for: second)
        XCTFail("the original reservation is still consuming the live slot")
    } catch WorkHostRegistryError.liveCapacityExceeded {
        XCTAssertTrue(true)
    }
    await registry.cancelRegistration(reservation)
    let released = try await registry.reserveRegistration(for: second)
    XCTAssertEqual(released.work, second)
    await registry.cancelRegistration(released)
    await registry.cancelRegistration(released)

    // Total capacity includes canonical facts and reservations, not only live actors.
    let totalRegistry = WorkHostRegistry(
        host: host,
        bounds: WorkHostRegistryBounds(maxEntries: 1, maxLiveEntries: 2, maxCanonicalEntries: 2))
    let canonicalWork = WorkRef(workHostID: host.workHostID, workID: "reservation-canonical")
    try await totalRegistry.registerCanonical(WorkHostRegistryCanonicalFact(
        work: canonicalWork, disposition: .historical, sourceID: "canonical-capacity"))
    do {
        _ = try await totalRegistry.reserveRegistration(
            for: WorkRef(workHostID: host.workHostID, workID: "reservation-over-total"))
        XCTFail("canonical entries and reservations share the total bound")
    } catch WorkHostRegistryError.capacityExceeded {
        XCTAssertTrue(true)
    }

    // Divergent Hosted identity cannot consume a reservation.  After that rejection the exact
    // actor still commits successfully, proving the reservation was not accidentally released.
    guard let runtimeHost = try makeHost(.reference) else { return }
    let actorHome = scratchHome()
    defer { try? FileManager.default.removeItem(at: actorHome.root) }
    let actorHost = try actorHome.requirePersistedWorkHost()
    let actorRegistry = WorkHostRegistry(
        host: actorHost, instanceID: "reservation-commit-instance",
        startIdentity: "reservation-commit-start",
        bounds: WorkHostRegistryBounds(maxEntries: 4, maxLiveEntries: 2, maxCanonicalEntries: 4))
    let actorWork = WorkRef(workHostID: actorHost.workHostID, workID: "reservation-commit")
    let divergentWork = WorkRef(workHostID: actorHost.workHostID, workID: "reservation-divergent")
    let actorReservation = try await actorRegistry.reserveRegistration(
        for: actorWork, launchMetadata: metadata)
    let divergentActor = try await reservationHostedWork(
        home: actorHome, work: divergentWork, runID: "reservation-divergent-run",
        runtimeHost: runtimeHost)
    do {
        _ = try await actorRegistry.commitRegistration(actorReservation, hostedWork: divergentActor)
        XCTFail("a divergent Hosted identity must be rejected")
    } catch WorkHostRegistryError.divergentRegistration(expected: actorWork, actual: divergentWork) {
        XCTAssertTrue(true)
    }
    let exactActor = try await reservationHostedWork(
        home: actorHome, work: actorWork, runID: "reservation-commit-run", runtimeHost: runtimeHost)
    let committed = try await actorRegistry.commitRegistration(
        actorReservation, hostedWork: exactActor)
    XCTAssertEqual(committed.work, actorWork)
    XCTAssertEqual(await actorRegistry.liveCount, 1)
    await reservationStop(divergentActor, commandID: "reservation-stop-divergent")
    await reservationStop(exactActor, commandID: "reservation-stop-exact")

    let concurrentRegistry = WorkHostRegistry(
        host: host,
        instanceID: "reservation-concurrent-instance",
        startIdentity: "reservation-concurrent-start",
        bounds: WorkHostRegistryBounds(
            maxEntries: 8, maxLiveEntries: 1, maxCanonicalEntries: 8))
    let outcomes = await withTaskGroup(of: WorkHostRegistryRegistrationReservation?.self,
                                       returning: [WorkHostRegistryRegistrationReservation?].self) { group in
        for index in 0..<16 {
            group.addTask {
                do {
                    let value = try await concurrentRegistry.reserveRegistration(
                        for: WorkRef(
                            workHostID: host.workHostID,
                            workID: "concurrent-reservation-\(index)"))
                    // Keep the winner occupied until all contenders have observed the fence.
                    return value
                } catch {
                    return nil
                }
            }
        }
        var values: [WorkHostRegistryRegistrationReservation?] = []
        for await value in group { values.append(value) }
        return values
    }
    let winners = outcomes.compactMap { $0 }
    XCTAssertEqual(winners.count, 1)
    // A losing task never owns cleanup of the winner; the admission owner explicitly cancels it
    // after the task group so a successful reservation cannot leak capacity.
    await concurrentRegistry.cancelRegistration(winners[0])
    let afterWinner = try await concurrentRegistry.reserveRegistration(
        for: WorkRef(workHostID: host.workHostID, workID: "concurrent-after-cancel"))
    await concurrentRegistry.cancelRegistration(afterWinner)
}

func testJournalBackedWorkServiceRequiresExactCanonicalEvidenceForAcceptedReceipt() throws {
    let host = WorkHostRef("receipt-evidence-host")
    let work = WorkRef(workHostID: host.workHostID, workID: "receipt-evidence-work")
    let journal = JournalRef.work(work, journalID: "receipt-evidence-journal")
    let client = ClientRef("receipt-evidence-client")
    let attachment = SessionAttachmentRef("receipt-evidence-attachment")
    let causal = JournalCursor(journal: journal, eventID: "work-2", sequence: 2)
    let request = WorkServiceCommandRequest(
        work: work, journal: journal, attachment: ClientAttachmentRef("receipt-client-attachment"),
        commandID: "caller-command", client: client, sessionAttachment: attachment,
        causalWorkCursor: causal, kind: .send, value: "hello")
    var snapshot = WorkSnapshot()
    snapshot.journal = journal
    snapshot.work = work
    snapshot.workHost = host
    snapshot.lifecycle = .active

    do {
        _ = try JournalBackedWorkServiceCommandEvidence.resolve(
            snapshot: snapshot, journal: journal, request: request, client: client)
        XCTFail("Hosted admission without a canonical command event must fail closed")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }

    let canonical = WorkServiceCommandLedgerIdentity.command(
        from: request.command, client: client)
    let acceptance = EventRef(journal: journal, eventID: "command-accepted-3")
    snapshot.commands[canonical.commandID] = WorkCommandSnapshot(
        command: canonical, state: .accepted,
        actor: TimelineActor(actorID: "receipt-evidence-host", kind: "work-service"),
        hostSequence: 17, idempotencyKey: canonical.commandID,
        acceptanceEventRef: acceptance)
    snapshot.eventSequences[acceptance.eventID] = 3
    let exact = try JournalBackedWorkServiceCommandEvidence.resolve(
        snapshot: snapshot, journal: journal, request: request, client: client)
    XCTAssertEqual(exact.cursor, JournalCursor(
        journal: journal, eventID: acceptance.eventID, sequence: 3))
    XCTAssertEqual(exact.hostSequence, 17)

    snapshot.eventSequences[acceptance.eventID] = causal.sequence
    do {
        _ = try JournalBackedWorkServiceCommandEvidence.resolve(
            snapshot: snapshot, journal: journal, request: request, client: client)
        XCTFail("a non-forward acceptance event must not become a success receipt")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }
}

let casesJournalBackedWorkService: [Case] = [
    ("journal-backed service joins exact concurrent Start and rejects newer cursor", {
        try await testJournalBackedWorkServiceJoinsExactStartAndRejectsNewerCursor()
    }),
    ("journal-backed service reconciles delivered Start after restart without redispatch", {
        try await testJournalBackedWorkServiceRestartReconcilesDeliveredStartWithoutRedispatch()
    }),
    ("journal-backed service rejects same-flat prompt source drift", {
        try await testJournalBackedWorkServiceRejectsSameFlatDifferentPromptSources()
    }),
    ("journal-backed service reserves Start before prompt assembly", {
        try await testDurableStartAdapterReservesBeforeAssemblyAndReusesRecordedPrompt()
    }),
    ("journal-backed service leaves assembly crash reservation closed", {
        try await testDurableStartAssemblyCrashReservationFailsClosedWithoutReassembly()
    }),
    ("journal-backed service binds Start to exact retained input", {
        try await testJournalBackedWorkServiceBindsPerRunStartInputAndAcceptsEmptyDigest()
    }),
    ("journal-backed service requires durable launch material", {
        try await testJournalBackedWorkServiceRequiresLaunchMaterial()
    }),
    ("journal-backed service Create remains idle with production material", {
        try await testJournalBackedWorkServiceCreateStaysIdleWithProductionManifest()
    }),
    ("journal-backed service publishes and reopens Create Session evidence", {
        try await testJournalBackedWorkServicePublishesCreateSessionAndReopensItsEvidence()
    }),
    ("journal-backed service bounds Session/client relationships without breaking retry", {
        try await testJournalBackedWorkServiceSessionAndClientBoundsPreserveExactRetry()
    }),
    ("journal-backed service rejects terminal Session publication before source writes", {
        try await testJournalBackedWorkServiceTerminalSessionRequiresObserveBeforePublication()
    }),
    ("journal-backed service publishes terminal Session references and reopens", {
        try await testJournalBackedWorkServicePublishesTerminalSessionReferenceAndReopens()
    }),
    ("journal-backed service keeps secondary Session client detach durable", {
        try await testJournalBackedWorkServiceSecondarySessionDetachStaysDetachedAfterRestart()
    }),
    ("journal-backed service classifies pre-marker Start as recovery", {
        try await testJournalBackedWorkServiceDoesNotProjectPreMarkerStartAsIdle()
    }),
    ("journal-backed service list requires observe", {
        try await testJournalBackedWorkServiceListRequiresObserveCapability()
    }),
    ("journal-backed service list isolates unavailable descriptor", {
        try await testJournalBackedWorkServiceListIsolatesUnavailableDescriptorAndProgresses()
    }),
    ("journal-backed service never projects an unproven Run as live", {
        try await testJournalBackedWorkServiceRecoveryNeverProjectsUnprovenRunAsLive()
    }),
    ("journal-backed service retries post-template crash", {
        try await testJournalBackedWorkServiceRetriesCrashAfterTemplatePublication()
    }),
    ("journal-backed service repairs reservation without rerunning resolver", {
        try await testJournalBackedWorkServiceRepairsReservationWithoutRerunningResolver()
    }),
    ("journal-backed service recovers retention before reservation", {
        try await testJournalBackedWorkServiceRecoversRetainedDraftBeforeReservation()
    }),
    ("journal-backed service reconstructs a lost Create response", {
        try await testJournalBackedWorkServiceCreatesCanonicalPairAndReconstructsLostResponse()
    }),
    ("journal-backed service reconciles exact control mutation retries", {
        try await testJournalBackedWorkServiceReconcilesExactControlMutationRetries()
    }),
    ("journal-backed service reads Work and Session through multiple pages", {
        try await testJournalBackedWorkServiceReadsLongWorkAndSessionJournalsThroughControllerPages()
    }),
    ("journal-backed service keeps oversized journals readable and incrementally cached", {
        try await testJournalBackedWorkServiceKeepsOversizedJournalsReadableAndIncrementallyCached()
    }),
    ("journal-backed service fails closed on corrupt source", {
        try await testJournalBackedWorkServiceFailsClosedOnCorruptSource()
    }),
    ("journal-backed service continues partial idle genesis", {
        try await testJournalBackedWorkServiceContinuesEveryIdleGenesisPrefix()
    }),
    ("journal-backed service rejects impossible idle genesis presence states", {
        try await testJournalBackedWorkServiceRejectsImpossibleIdleGenesisPresenceStates()
    }),
    ("journal-backed service fences registry reservations", {
        try await testJournalBackedWorkServiceRegistryReservationsAreBoundedAndFenced()
    }),
    ("journal-backed service requires exact canonical command receipt evidence", {
        try testJournalBackedWorkServiceRequiresExactCanonicalEvidenceForAcceptedReceipt()
    }),
    ("journal-backed service refreshes workspace catalog per handshake", {
        try await testJournalBackedWorkspaceCatalogRefreshesPerHandshakeAndFailsClosed()
    }),
    ("journal-backed service bounds and shares workspace catalog probes", {
        try await testJournalBackedWorkspaceCatalogProbeIsBoundedAndShared()
    }),
]
