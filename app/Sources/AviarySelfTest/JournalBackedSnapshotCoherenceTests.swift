import Foundation
@testable import AviaryCore

private actor JournalBackedSnapshotInterleave {
    private let home: AgentHome
    private let binding: WorkBinding
    private var sawWorkPage = false
    private var sawSessionPage = false
    private var mutationStarted = false
    private var mutationFinished = false
    private var workRequestSequences: [Int] = []
    private var sessionRequestSequences: [Int] = []
    private var failure: String?

    init(home: AgentHome, binding: WorkBinding) {
        self.home = home
        self.binding = binding
    }

    func afterPage(_ request: WorkServiceSnapshotRequest) async {
        switch request.target {
        case .work:
            sawWorkPage = true
            workRequestSequences.append(request.afterCursor?.sequence ?? 0)
        case .session:
            sawSessionPage = true
            sessionRequestSequences.append(request.afterCursor?.sequence ?? 0)
        }

        if sawWorkPage && sawSessionPage && !mutationStarted {
            mutationStarted = true
            do {
                let bundle = try await RunJournalBundle.openForExecution(
                    home: home,
                    binding: WorkRunBinding(
                        workBinding: binding, run: RunRef("snapshot-coherence-run")),
                    actorID: "snapshot-coherence-writer")
                do {
                    _ = try await bundle.finishRun()
                    try await bundle.closeChecked()
                    mutationFinished = true
                } catch {
                    try? await bundle.closeChecked()
                    throw error
                }
            } catch {
                failure = String(describing: error)
            }
            return
        }

        if !mutationFinished && failure == nil {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !mutationFinished && failure == nil && !Task.isCancelled
                    && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if !mutationFinished && failure == nil {
                mutationStarted = true
                failure = Task.isCancelled
                    ? "snapshot interleave was cancelled"
                    : "both snapshot target pages were not observed within five seconds"
            }
        }
    }

    func snapshot() -> (
        mutationFinished: Bool,
        workRequestSequences: [Int],
        sessionRequestSequences: [Int],
        failure: String?
    ) {
        (mutationFinished, workRequestSequences, sessionRequestSequences, failure)
    }
}

private func snapshotCoherenceHome() throws -> (AgentHome, URL) {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(
        path: "ajbs-" + UUID().uuidString.lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return (AgentHome(root: root), root)
}

private func testJournalBackedSnapshotRetainsOneCanonicalSourceAcrossDescriptorAssembly()
    async throws {
    let (home, root) = try snapshotCoherenceHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = ClientRef("snapshot-coherence-client")
    let capabilities: Set<WorkServiceCapability> = [.observe, .control]
    let host = try home.requirePersistedWorkHost()
    let manifests = DurableJournalBackedWorkLaunchManifestStore(
        store: WorkLaunchManifestStore(home: home), bodyAuthority: .workHost(host),
        draftResolver: { request in
            WorkLaunchManifestDraft(
                workspace: WorkLaunchWorkspace(locator: root.path, policy: .temporary),
                runtime: WorkLaunchRuntime(
                    providerID: "snapshot-provider", modelID: "snapshot-model", runtimeVariant: "test"),
                configuration: request.configuration,
                requestedCapabilities: request.requestedCapabilities,
                provenance: WorkLaunchManifestProvenance(source: "snapshot-coherence-test"))
        })
    let service = try JournalBackedWorkService(
        home: home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: capabilities]),
        manifestStore: manifests)
    do {
        let controlCursor = try await service.handshake(
            WorkServiceHandshakeRequest(client: client)).controlCursor
        let created = try await service.createWork(WorkServiceCreateWorkRequest(
            client: client, commandID: "snapshot-coherence-create",
            causalControlCursor: controlCursor,
            configuration: WorkServiceWorkConfiguration(
                providerID: "snapshot-provider", modelID: "snapshot-model"),
            requestedCapabilities: capabilities))
        let intentStore = try WorkServiceAttachedWorkIntentStore(
            url: root.appendingPathComponent("controller-intent.json"))
        let controller = try WorkServiceAttachedWorkController(
            service: service, seed: .created(created), intentStore: intentStore)
        let initial = try await controller.refresh()
        XCTAssertTrue(initial.isCanonical)
        XCTAssertEqual(initial.descriptor.execution, .idle)
        XCTAssertNil(initial.descriptor.currentRun)
        XCTAssertTrue(initial.workCursor.sequence > 0)
        XCTAssertTrue(initial.sessionCursor.sequence > 0)

        let binding = WorkBinding(
            session: created.session, work: created.work.work,
            workHost: WorkHostRef(created.work.work.workHostID),
            sessionAttachment: created.sessionAttachment)
        let interleave = JournalBackedSnapshotInterleave(home: home, binding: binding)
        await service.installSnapshotAfterPageHook { request in
            await interleave.afterPage(request)
        }

        // Both target pages are selected from the old actor-serialized canonical pair. The hook
        // advances and closes a complete Run before either response assembles its descriptor. A
        // second canonical read here would describe the newer tip and contradict the old page.
        let raced = try await controller.refresh()
        let afterRace = await interleave.snapshot()
        XCTAssertTrue(afterRace.mutationFinished, afterRace.failure ?? "interleave did not run")
        XCTAssertNil(afterRace.failure)
        XCTAssertTrue(raced.isCanonical)
        XCTAssertEqual(raced.workCursor, initial.workCursor)
        XCTAssertEqual(raced.sessionCursor, initial.sessionCursor)
        XCTAssertEqual(raced.descriptor.currentRun, raced.workSnapshot.activeRun)
        XCTAssertTrue(raced.descriptor.attachments.contains(where: {
            $0.attachment == created.attachment.attachment
                && $0.client == client
                && $0.authorization.granted.contains(.observe)
        }))

        // The next ordinary incremental poll observes the appended Run pair. No source failure
        // means the controller never falls back to zero, and refresh never invents a command.
        let recovered = try await controller.refresh()
        let afterRecovery = await interleave.snapshot()
        XCTAssertTrue(recovered.isCanonical)
        XCTAssertTrue(recovered.workCursor.sequence > raced.workCursor.sequence)
        XCTAssertTrue(recovered.sessionCursor.sequence > raced.sessionCursor.sequence)
        XCTAssertEqual(recovered.descriptor.currentRun, recovered.workSnapshot.activeRun)
        XCTAssertEqual(recovered.descriptor.execution, .idle)
        XCTAssertTrue(recovered.workSnapshot.commands.isEmpty)
        XCTAssertNil(await controller.pendingCommand())
        XCTAssertEqual(afterRecovery.workRequestSequences.count, 2)
        XCTAssertEqual(afterRecovery.sessionRequestSequences.count, 2)
        XCTAssertTrue(afterRecovery.workRequestSequences.allSatisfy { $0 > 0 })
        XCTAssertTrue(afterRecovery.sessionRequestSequences.allSatisfy { $0 > 0 })
        await service.installSnapshotAfterPageHook(nil)
        await service.controlJournal.close()
    } catch {
        await service.installSnapshotAfterPageHook(nil)
        await service.controlJournal.close()
        throw error
    }
}

let casesJournalBackedSnapshotCoherence: [Case] = [
    ("JBS snapshot retains one canonical source across descriptor assembly", {
        try await testJournalBackedSnapshotRetainsOneCanonicalSourceAcrossDescriptorAssembly()
    }),
]
