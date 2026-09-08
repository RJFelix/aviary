import AviaryCore
import Foundation

/// Exercises the actual AppModel launch/save boundary without contacting a model or reading
/// user transcripts. Run the signed app with --chat-journey-probe; all data is temporary.
enum ChatJourneyProbe {
    @MainActor static func runIfRequested() {
        guard CommandLine.arguments.contains("--chat-journey-probe") else { return }
        let done = Atomic(false)
        Task { @MainActor in
            do {
                try await run()
                print("chat journey: exact save, blocked launch, relaunch, edit, retry, and save failure PASS")
                done.set(true)
            } catch {
                FileHandle.standardError.write(Data("chat journey probe FAILED: \(error)\n".utf8))
                exit(1)
            }
        }
        while !done.get() {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        exit(0)
    }

    private enum Failure: Error { case assertion(String) }
    @MainActor private static func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        guard condition() else { throw Failure.assertion(reason) }
    }

    @MainActor private static func waitForAttempt(_ model: AppModel, id: UUID) async throws {
        for _ in 0..<100 {
            guard let chat = model.pendingChats.first(where: { $0.id == id }) else {
                throw Failure.assertion("chat disappeared")
            }
            if !model.pendingChatIsPreparing(chat) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.assertion("preflight did not settle")
    }

    /// Exercise the AppModel LiveRun restore guard against a real canonical in-memory host.
    /// This stays below bootstrap/model/GUI boundaries: Create is the only host setup, and the
    /// Start seed is retained exactly as it would be across a process restart.
    @MainActor private static func makeServiceProbeRun(
        service: InMemoryWorkService,
        response: WorkServiceCreateWorkResponse,
        home: AgentHome,
        prompt: String,
        commandID: String
    ) async throws -> LiveRun {
        guard let key = ServiceAttachmentKey(
            work: response.work.work, attachment: response.attachment) else {
            throw Failure.assertion("canonical Create response had no attachment key")
        }
        let intentStore = try WorkServiceAttachedWorkIntentStore(home: home, key: key)
        let controller = try WorkServiceAttachedWorkController(
            service: service, seed: .created(response), intentStore: intentStore)
        let projection = try await controller.refresh()
        let start = try ServiceBackedStartIntent(
            client: response.attachment.client,
            work: response.work.work,
            session: response.session,
            sessionJournal: response.sessionJournal,
            sessionAttachment: response.sessionAttachment,
            clientAttachment: response.attachment.attachment,
            causalWorkCursor: response.workCursor,
            commandID: commandID,
            prompt: prompt)
        let startStore = try ServiceBackedStartIntentStore(home: home, key: key)
        try startStore.retain(start)
        let bridge = ServiceBackedRunBridge(
            controller: controller,
            projection: projection,
            history: await controller.conversationHistory(),
            serviceAttachmentKey: key,
            workspaceLabel: "journey-probe",
            modelLabel: nil,
            thinkingLevel: nil)
        return LiveRun(
            service: bridge,
            initialStart: start,
            initialStartStore: startStore)
    }

    @MainActor private static func runServiceInitialStartProbe(root: URL) async throws {
        let home = AgentHome(root: root.appending(
            path: "service-home", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        let host = WorkHostRef("journey-probe-host")
        let client = ClientRef("journey-probe-client")
        let grants = Set(WorkServiceCapability.allCases)
        let service = InMemoryWorkService(
            host: host,
            instanceID: "journey-probe-instance",
            startIdentity: "journey-probe-start",
            authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]))
        let first = try await service.createWork(.init(
            client: client,
            commandID: "journey-create-guarded",
            causalControlCursor: JournalCursor(
                journal: .workHost(host), sequence: 0),
            requestedCapabilities: grants))
        let guarded = try await makeServiceProbeRun(
            service: service, response: first, home: home,
            prompt: "preserve this initial prompt", commandID: "journey-start-guarded")
        guarded.initialStartRequiresExplicitRetry = true
        await guarded.refreshService()
        guard let guardedProjection = guarded.serviceProjection else {
            throw Failure.assertion("guarded service run lost its projection")
        }
        try require(
            guarded.savedInitialPrompt == "preserve this initial prompt",
            "explicit-retry restore dropped the retained initial prompt")
        try require(
            guardedProjection.workSnapshot.commands.values.allSatisfy {
                $0.commandKind != .start
            } && guardedProjection.descriptor.currentRun == nil
                && guardedProjection.workSnapshot.activeRun == nil,
            "explicit-retry restore admitted Start during refresh")

        // A fresh idle Work proves the control: ordinary reconstruction still admits exactly one
        // Start, and the canonical follow-up refresh resolves its retained marker.
        let latest = try await service.handshake(.init(client: client))
        let second = try await service.createWork(.init(
            client: client,
            commandID: "journey-create-default",
            causalControlCursor: latest.controlCursor,
            requestedCapabilities: grants))
        let ordinary = try await makeServiceProbeRun(
            service: service, response: second, home: home,
            prompt: "ordinary initial prompt", commandID: "journey-start-default")
        await ordinary.refreshService(resumeInitialStart: false)
        try require(ordinary.serviceProjection?.descriptor.currentRun == nil
                    && ordinary.savedInitialPrompt == "ordinary initial prompt",
                    "observation-only poll admitted or dropped a retained Start")
        await ordinary.refreshService()
        await ordinary.refreshService()
        guard let ordinaryProjection = ordinary.serviceProjection else {
            throw Failure.assertion("ordinary service run lost its projection")
        }
        let starts = ordinaryProjection.workSnapshot.commands.values.filter {
            $0.commandKind == .start
        }
        try require(starts.count == 1 && ordinaryProjection.descriptor.currentRun != nil,
                    "default restore did not admit exactly one canonical Start")
    }

    @MainActor private static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "aviary-chat-journey-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        let model = AppModel()
        model.home = home
        let internalFailure = AppModel.serviceErrorMessage(WorkServiceTransportError.remote(
            code: .internalError, detail: "credential-shaped-private-detail"))
        try require(internalFailure.contains("internal error") && !internalFailure.contains("credential-shaped"),
                    "service failure diagnostic hid classification or exposed raw detail")
        model.localWorkServiceCreateError = internalFailure
        // This is what a successful catalog refresh used to do: it must not erase the
        // independent outstanding Create failure or make Diagnostics look fully healthy.
        model.localWorkServiceError = nil
        try require(model.localWorkServiceError == internalFailure, "catalog success erased Create failure")
        model.localWorkServiceError = "Connection interrupted"
        try require(model.localWorkServiceError == "Connection interrupted",
                    "disconnected state was hidden behind a prior Create failure")
        model.localWorkServiceError = nil
        model.localWorkServiceCreateError = nil
        try require(model.localWorkServiceError == nil, "resolved Create kept stale failure")
        // Larger than the service limit but inside the local save limit. No provider/bootstrap
        // call is reachable; this is a deterministic pre-admission failure.
        let exact = String(repeating: "A🙂\n", count: 2_000)
        try require(model.createPendingChat(cwd: root.path, providerID: nil, modelID: nil,
                                           prompt: exact), "initial save rejected")
        guard let saved = model.pendingChats.first else { throw Failure.assertion("no visible saved chat") }
        try require(saved.prompt == exact && model.selectedPendingChatID == saved.id, "prompt/selection mismatch")
        try await waitForAttempt(model, id: saved.id)
        try require(model.pendingChats.first?.phase == .blocked, "failure not attached to chat")
        try require(model.runs.isEmpty, "failed preflight fabricated a Run")

        let reopened = AppModel()
        reopened.home = home
        reopened.restorePendingChats()
        guard let restored = reopened.pendingChats.first else { throw Failure.assertion("relaunch lost chat") }
        try require(restored.id == saved.id && restored.prompt == exact, "relaunch changed prompt")
        try require(reopened.selectedPendingChatID == nil, "restored failure stole return selection")
        try require(reopened.editPendingChat(restored, prompt: exact + "edited", cwd: root.path,
                                            providerID: "unconfigured", modelID: "unconfigured"), "edit failed")
        reopened.retryPendingChat(restored.id)
        reopened.retryPendingChat(restored.id)
        try await waitForAttempt(reopened, id: restored.id)
        try require(reopened.pendingChats.count == 1 && reopened.pendingChats[0].prompt == exact + "edited",
                    "retry duplicated or dropped saved chat")
        try require(reopened.runs.isEmpty, "oversized retry contacted executor")
        reopened.discardPendingChat(reopened.pendingChats[0])
        try require(reopened.pendingChats.isEmpty, "unsent chat could not be discarded")
        let afterDiscard = try PendingChatStore(home: home).load()
        try require(afterDiscard.rows.isEmpty, "discard left its local saved card")

        // An associated but unresolved startup has a reviewed escape, not an automatic resend.
        let work = WorkRef(workHostID: "probe-host", workID: "probe-work")
        let session = SessionRef("probe-session")
        guard let workSession = WorkSessionKey(work: work, session: session,
            sessionJournal: .session(session, journalID: "probe-journal",
                                     authority: TimelineAuthorityRef("probe-host")),
            sessionAttachment: SessionAttachmentRef("probe-session-attachment")),
              let key = ServiceAttachmentKey(client: ClientRef("probe-client"),
                clientAttachment: ClientAttachmentRef("probe-client-attachment"), workSession: workSession)
        else { throw Failure.assertion("invalid probe association") }
        let store = try PendingChatStore(home: home)
        let seed = try store.create(prompt: "keep the unresolved original", cwd: root.path)
        let associated = try store.update(seed.changing(
            phase: .awaitingAcceptance, createdAssociation: key), expectedGeneration: seed.generation)
        reopened.pendingChats = [associated]
        reopened.copyPendingChatAsUnsent(associated)
        guard let copy = reopened.pendingChats.first(where: { $0.id != associated.id }) else {
            throw Failure.assertion("separate copy missing")
        }
        try require(copy.prompt == associated.prompt && copy.phase == .saved
                    && copy.createdAssociation == nil && copy.startCommandID != associated.startCommandID,
                    "copy was not a separate unsent request")
        try require(!reopened.pendingChatIsPreparing(copy) && reopened.runs.isEmpty,
                    "copy unexpectedly started work")
        reopened.stopTrackingPendingChat(associated)
        try require(reopened.pendingChats.map(\.id) == [copy.id], "tracking dismissal removed the copy")
        reopened.discardPendingChat(copy)
        try require(reopened.pendingChats.isEmpty, "copy could not be discarded")

        let unavailableRoot = root.appending(path: "not-a-directory")
        try Data("test-owned blocker".utf8).write(to: unavailableRoot)
        let failedSave = AppModel()
        failedSave.home = AgentHome(root: unavailableRoot)
        try require(!failedSave.createPendingChat(cwd: root.path, providerID: nil, modelID: nil,
                                                 prompt: "keep this in the editor"), "save failure claimed success")
        try require(failedSave.pendingChats.isEmpty && failedSave.pendingChatStoreError != nil,
                    "save failure missing visible explanation")

        try await runServiceInitialStartProbe(root: root)
    }
}
