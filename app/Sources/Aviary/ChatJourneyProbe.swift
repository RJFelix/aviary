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
                await AviaryTelemetry.shutdown(maximumDuration: 2)
                print("chat journey: exact save, blocked launch, relaunch, edit, retry, and save failure PASS")
                done.set(true)
            } catch {
                await AviaryTelemetry.shutdown(maximumDuration: 2)
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

        // The durable intent is conservatively uncertain before the transport call returns.
        // Only this GUI's live request lifetime can distinguish sending from lost confirmation;
        // reopening must continue to show the latter, never pretend a call is still alive.
        guard let originalBridge = guarded.serviceBridge else {
            throw Failure.assertion("guarded service run lost its bridge")
        }
        // The same last-known canonical rows can remain on screen after disconnect. They must
        // not keep the activity strip looking live or turn unavailable child evidence into zero.
        for connected in [true, false] {
            var work = guardedProjection.workSnapshot
            work.childStates = ["recorded-child": "running"]
            let activityProjection = WorkServiceAttachedWorkProjection(
                descriptor: guardedProjection.descriptor,
                attachment: guardedProjection.attachment,
                capabilities: guardedProjection.capabilities,
                workSnapshot: work, sessionSnapshot: guardedProjection.sessionSnapshot,
                workCursor: guardedProjection.workCursor, sessionCursor: guardedProjection.sessionCursor,
                workSourceCompleteness: .complete, sessionSourceCompleteness: .complete,
                connectivity: connected ? guardedProjection.connectivity : .disconnected)
            let activityBridge = ServiceBackedRunBridge(
                controller: originalBridge.controller, projection: activityProjection,
                history: originalBridge.history, serviceAttachmentKey: originalBridge.serviceAttachmentKey,
                workspaceLabel: "activity-probe", modelLabel: nil, thinkingLevel: nil)
            let activityRun = LiveRun(service: activityBridge, cwd: home.root.path, title: "activity-probe")
            try require(activityRun.serviceActivitySourceIsCurrent == connected,
                        "activity freshness did not follow the actual bridge connection")
            try require(activityRun.childActivity.hasRecords,
                        "disconnect erased retained child lifecycle evidence")
            try require(activityRun.chatActivity.sourceIsComplete == connected,
                        "activity summary claimed a disconnected view was current")
        }
        let pending = WorkServiceAttachedWorkPendingCommand(
            state: .indeterminate, kind: .start, commandID: "presentation-probe",
            client: client, attachment: first.attachment.attachment,
            sessionAttachment: first.sessionAttachment,
            causalWorkCursor: first.workCursor, valueDigest: nil)
        let presentationDraftStore = try ServiceBackedDraftStore(
            home: home, key: originalBridge.serviceAttachmentKey)
        let presentationDraft = try presentationDraftStore.beginHandoff(
            text: "saved input", kind: .start, commandID: "presentation-probe",
            expectedGeneration: nil)
        for inFlight in [true, false] {
            let projection = WorkServiceAttachedWorkProjection(
                descriptor: guardedProjection.descriptor,
                attachment: guardedProjection.attachment,
                capabilities: guardedProjection.capabilities,
                workSnapshot: guardedProjection.workSnapshot,
                sessionSnapshot: guardedProjection.sessionSnapshot,
                workCursor: guardedProjection.workCursor,
                sessionCursor: guardedProjection.sessionCursor,
                workSourceCompleteness: .complete, sessionSourceCompleteness: .complete,
                connectivity: guardedProjection.connectivity,
                pendingCommand: pending, commandInFlight: inFlight)
            let bridge = ServiceBackedRunBridge(
                controller: originalBridge.controller, projection: projection,
                history: originalBridge.history,
                serviceAttachmentKey: originalBridge.serviceAttachmentKey,
                workspaceLabel: "presentation-probe", modelLabel: nil, thinkingLevel: nil)
            let run = LiveRun(service: bridge, cwd: home.root.path, title: "presentation-probe",
                              draftStore: presentationDraftStore, restoredDraft: presentationDraft)
            run.observeService()
            try require(run.serviceCommandInFlight == inFlight,
                        "request lifetime was not mirrored into the actual chat presentation")
            try require((run.errorBanner == nil) == inFlight,
                        "sending must not claim failure, and lost confirmation must remain visible")
            try require((run.draftPersistenceNotice == nil) == inFlight,
                        "an in-flight handoff is not a draft-storage failure")
            if inFlight {
                try require(!bridge.canRetryPendingCommand, "live original request exposed a duplicate retry")
                try require(!run.acceptsInput && !run.serviceControlsAvailable,
                            "live original request left mutation controls enabled")
            }
        }

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

        // Startup restoration admits attachments one at a time. Once the first visible chat has
        // become the implicit presentation choice, later background rows must not retarget its
        // composer or override a pre-existing explicit focus.
        var restoredRuns = [guarded]
        var restoredFocus = AppModel.focusAfterBackgroundServiceRestore(
            current: nil, admitted: guarded.id)
        guarded.setDraft("draft stays with the first restored chat")
        restoredRuns.append(ordinary)
        restoredFocus = AppModel.focusAfterBackgroundServiceRestore(
            current: restoredFocus, admitted: ordinary.id)
        let restoredSelection = restoredRuns.first { $0.id == restoredFocus }
        try require(
            restoredSelection?.id == guarded.id
                && restoredSelection?.draft == "draft stays with the first restored chat"
                && ordinary.draft.isEmpty,
            "later background restoration retargeted the visible composer")
        let explicitFocus = AppModel.focusAfterBackgroundServiceRestore(
            current: ordinary.id, admitted: guarded.id)
        try require(explicitFocus == ordinary.id,
                    "background restoration overrode an existing run focus")

        // Relaunch selection is keyed by the exact durable attachment, never LiveRun's
        // process-local UUID. Isolate UserDefaults so this probe cannot change real GUI choices.
        let suiteName = "aviary-chat-journey-" + UUID().uuidString.lowercased()
        guard let selectionDefaults = UserDefaults(suiteName: suiteName),
              let guardedKey = guarded.serviceAttachmentKey,
              let ordinaryKey = ordinary.serviceAttachmentKey else {
            throw Failure.assertion("could not create an isolated selection preference")
        }
        defer { selectionDefaults.removePersistentDomain(forName: suiteName) }
        let firstLaunch = AppModel(home: home, presentationDefaults: selectionDefaults)
        firstLaunch.focusRun(ordinary)
        let reopenedLaunch = AppModel(home: home, presentationDefaults: selectionDefaults)
        try require(
            reopenedLaunch.preferredServiceAttachmentKey == ordinaryKey
                && reopenedLaunch.preferredServiceAttachmentKey != guardedKey,
            "relaunch did not retain the exact selected service attachment")
        try require(
            AppModel.preferredServiceRestoreIndex(
                candidates: [guardedKey, ordinaryKey],
                preferred: reopenedLaunch.preferredServiceAttachmentKey) == 1,
            "relaunch could not prioritize the selected attachment over catalog order")
        try require(
            AppModel.preferredServiceRestoreIndex(
                candidates: [guardedKey], preferred: ordinaryKey) == nil,
            "a missing or hidden attachment preference matched another candidate")

        // During cold host replay the canonical Session rail can be available before its live
        // attachment. The exact saved relationship may provisionally select that one row once
        // this process has loaded the same durable client, without claiming attachment ownership.
        let guardedCandidate = AppModel.CanonicalWorkspaceSelectionCandidate(
            id: "guarded-session", workTargets: [guardedKey.workSession])
        let ordinaryCandidate = AppModel.CanonicalWorkspaceSelectionCandidate(
            id: "ordinary-session", workTargets: [ordinaryKey.workSession])
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [guardedCandidate, ordinaryCandidate],
                explicitID: nil, focusedID: nil, preferred: ordinaryKey,
                ownedKeys: [], localClient: client) == ordinaryCandidate.id,
            "cold restoration did not provisionally select the exact saved chat")
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [guardedCandidate, ordinaryCandidate],
                explicitID: guardedCandidate.id, focusedID: nil, preferred: ordinaryKey,
                ownedKeys: [], localClient: client) == guardedCandidate.id,
            "an explicit rail selection lost to provisional restoration")
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [guardedCandidate, ordinaryCandidate],
                explicitID: nil, focusedID: guardedCandidate.id, preferred: ordinaryKey,
                ownedKeys: [], localClient: client) == guardedCandidate.id,
            "an existing focused chat lost to provisional restoration")
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [guardedCandidate, ordinaryCandidate],
                explicitID: nil, focusedID: nil, preferred: ordinaryKey,
                ownedKeys: [], localClient: client,
                hasFocusedUnrepresentedRun: true) == nil,
            "a new focused live chat lost to a historical canonical row")
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [guardedCandidate, ordinaryCandidate],
                explicitID: guardedCandidate.id, focusedID: nil, preferred: ordinaryKey,
                ownedKeys: [], localClient: client,
                hasFocusedUnrepresentedRun: true) == guardedCandidate.id,
            "an explicit canonical selection lost to an unrepresented live focus")
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [guardedCandidate],
                explicitID: nil, focusedID: nil, preferred: ordinaryKey,
                ownedKeys: [], localClient: client) == nil,
            "an unrelated canonical row inherited the saved chat selection")
        let unknownOrdinaryCandidate = AppModel.CanonicalWorkspaceSelectionCandidate(
            id: "unknown-ordinary-session", workTargets: [ordinaryKey.workSession],
            isExact: false)
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [unknownOrdinaryCandidate],
                explicitID: nil, focusedID: nil, preferred: ordinaryKey,
                ownedKeys: [], localClient: client) == nil,
            "an unknown canonical relationship inherited the saved chat selection")
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [ordinaryCandidate],
                explicitID: nil, focusedID: nil, preferred: ordinaryKey,
                ownedKeys: [], localClient: ClientRef("foreign-client")) == nil,
            "a different GUI client inherited the saved chat selection")
        let duplicateOrdinaryCandidate = AppModel.CanonicalWorkspaceSelectionCandidate(
            id: "duplicate-ordinary-session", workTargets: [ordinaryKey.workSession])
        try require(
            AppModel.canonicalWorkspaceSelectionID(
                candidates: [ordinaryCandidate, duplicateOrdinaryCandidate],
                explicitID: nil, focusedID: nil, preferred: ordinaryKey,
                ownedKeys: [], localClient: client) == nil,
            "an ambiguous canonical relationship was provisionally selected")
        try require(
            AppModel.canonicalWorkspaceRestoringIDs(
                candidates: [guardedCandidate, ordinaryCandidate],
                restoringKeys: [ordinaryKey]) == [ordinaryCandidate.id],
            "restoration presentation marked an unrelated canonical row")
        try require(
            AppModel.canonicalWorkspaceRestoringIDs(
                candidates: [ordinaryCandidate, duplicateOrdinaryCandidate],
                restoringKeys: [ordinaryKey]).isEmpty,
            "restoration presentation marked an ambiguous canonical relationship")
        let multiWorkCandidate = AppModel.CanonicalWorkspaceSelectionCandidate(
            id: "multi-work-session",
            workTargets: [guardedKey.workSession, ordinaryKey.workSession])
        try require(
            AppModel.canonicalWorkspacePreferredTarget(
                candidate: multiWorkCandidate, preferred: ordinaryKey,
                ownedKeys: [], localClient: client) == ordinaryKey.workSession,
            "a multi-Work Session did not preserve the preferred exact Work relationship")
        let pendingSelection = UUID()
        reopenedLaunch.selectedPendingChatID = pendingSelection
        reopenedLaunch.newChatRequested = true
        reopenedLaunch.focusRun(guarded)
        try require(
            reopenedLaunch.selectedPendingChatID == pendingSelection
                && reopenedLaunch.newChatRequested,
            "background attachment focus erased pending or new-chat intent")

        // Model a response that was lost after the host recorded End. Exact canonical command
        // evidence retires only that uncertainty; a foreign command or ordinary local warning
        // must survive the same refresh path.
        guard let ordinaryBridge = ordinary.serviceBridge else {
            throw Failure.assertion("ordinary service run lost its bridge")
        }
        let endCommandID = "journey-end-lost-confirmation"
        _ = try await ordinaryBridge.end(commandID: endCommandID)
        let retainedEnd = await ordinaryBridge.controller.pendingCommand()
        try require(retainedEnd == nil,
                    "canonical End refresh did not clear its retained command")
        let certainty = await ordinaryBridge.failureCertainty(
            for: WorkServiceAttachedWorkControllerError.sourceIncomplete,
            commandID: endCommandID, kind: .end)
        try require(certainty == .uncertain,
                    "lost End response was presented as a proven rejection")
        let key = ordinaryBridge.serviceAttachmentKey
        let acknowledgement = ServiceBackedCommandNotice(
            work: ordinaryBridge.work, commandID: endCommandID, kind: .end,
            client: key.client, attachment: key.clientAttachment,
            sessionAttachment: key.workSession.sessionAttachment,
            evidence: .canonicalCommand)
        ordinary.commandNotice = .uncertain(
            "End confirmation was interrupted.", serviceAcknowledgement: acknowledgement)
        await ordinary.refreshService(resumeInitialStart: false)
        try require(ordinary.commandNotice == nil,
                    "exact canonical End did not retire its uncertainty notice")

        let foreignAcknowledgement = ServiceBackedCommandNotice(
            work: ordinaryBridge.work, commandID: "foreign-end", kind: .end,
            client: key.client, attachment: key.clientAttachment,
            sessionAttachment: key.workSession.sessionAttachment,
            evidence: .canonicalCommand)
        ordinary.commandNotice = .uncertain(
            "Foreign End confirmation was interrupted.",
            serviceAcknowledgement: foreignAcknowledgement)
        await ordinary.refreshService(resumeInitialStart: false)
        try require(ordinary.commandNotice?.serviceAcknowledgement == foreignAcknowledgement,
                    "canonical End cleared a foreign uncertainty notice")

        ordinary.commandNotice = .warning("Unrelated local draft error")
        await ordinary.refreshService(resumeInitialStart: false)
        try require(ordinary.commandNotice == .warning("Unrelated local draft error"),
                    "canonical End cleared an unrelated local warning")
    }

    @MainActor private static func runProjectReconfirmationProbe(root: URL) async throws {
        let home = AgentHome(root: root.appending(path: "project-reconfirmation-home"))
        let directory = root.appending(path: "project-reconfirmation-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try WorkHostWorkspaceRegistry(home: home)
        let registered = try registry.registerLocalDirectory(directory, label: "Project probe")
        let originalDirectory = try registry.resolve(registered.workspaceID)
        // Model the exact pre-volume-UUID failure seen after reboot, only in this owned fixture.
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: home.workHostWorkspaceRegistryFile)) as? [String: Any],
              var entries = object["entries"] as? [[String: Any]], entries.count == 1,
              var identity = entries[0]["filesystemIdentity"] as? [String: Any],
              let device = identity["device"] as? NSNumber else {
            throw Failure.assertion("project registry fixture shape changed")
        }
        identity["volumeUUID"] = nil
        identity["device"] = device.uint64Value + 1
        entries[0]["filesystemIdentity"] = identity
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: home.workHostWorkspaceRegistryFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.workHostWorkspaceRegistryFile.path)
        let unavailable = try registry.catalog().entries.first
        try require(unavailable?.unavailabilityReason == .identityNeedsConfirmation,
                    "workspace mismatch lost its specific reason")

        let store = try PendingChatStore(home: home)
        let chat = try PendingChat(prompt: "Preserve this exact request", cwd: directory.path,
            phase: .blocked, failureKind: .workspaceConfirmationRequired)
        try store.insert(chat)
        let model = AppModel(home: home)
        model.restorePendingChats()
        let originalBytes = try Data(contentsOf: home.workHostWorkspaceRegistryFile)
        let token = try model.preparePendingProjectReconfirmation(chatID: chat.id, directory: directory)
        let preparedBytes = try Data(contentsOf: home.workHostWorkspaceRegistryFile)
        try require(preparedBytes == originalBytes,
                    "choosing a folder mutated registration before confirmation")
        try require(model.runs.isEmpty && model.localWorkService == nil,
                    "preparing folder confirmation started a service or agent")
        let outcome = try await model.confirmPendingProjectReconfirmation(token, chatID: chat.id)
        if case .confirmedNeedsRefresh = outcome {} else {
            throw Failure.assertion("offline confirmation did not separate registry success from service refresh")
        }
        let resolved = try registry.resolve(registered.workspaceID)
        try require(resolved.path == originalDirectory.path,
                    "confirmation lost the original workspace identity")
        guard let saved = try store.load().rows.first else { throw Failure.assertion("confirmation lost saved chat") }
        try require(saved.phase == .saved && saved.failureKind == nil && saved.prompt == chat.prompt
                    && saved.attemptCommandID == chat.attemptCommandID
                    && saved.startCommandID == chat.startCommandID && saved.createdAssociation == nil,
                    "confirmation changed input identity, text, or delivery state")
        try require(model.runs.isEmpty && model.localWorkService == nil,
                    "confirming a project implicitly started a service or submitted input")
    }

    @MainActor private static func run() async throws {
        // This is the actual rail presentation gate, not a hand-built visual fixture. A
        // selected exact attachment may preserve a title, never repair canonical ambiguity.
        let attached = CanonicalWorkspaceRailPresentation.attachedFallback(
            entryIsKnown: false, entryJoin: .exact,
            attachedServiceBacked: true, attachedProjectionIsCanonical: true,
            attachedTitle: "Known chat title", attachedCommandState: .idle)
        try require(attached?.title == "Known chat title" && attached?.commandState == .idle,
                    "exact unknown catalog discarded attached chat identity")
        let incompleteAttached = CanonicalWorkspaceRailPresentation.attachedFallback(
            entryIsKnown: false, entryJoin: .incomplete,
            attachedServiceBacked: true, attachedProjectionIsCanonical: true,
            attachedTitle: "Known chat title", attachedCommandState: .idle)
        try require(incompleteAttached == attached,
                    "incomplete catalog lost the existing attached chat fallback")
        for join in [CanonicalSessionWorkspaceRailJoin.duplicateSummary, .missingSummary] {
            try require(CanonicalWorkspaceRailPresentation.attachedFallback(
                entryIsKnown: false, entryJoin: join,
                attachedServiceBacked: true, attachedProjectionIsCanonical: true,
                attachedTitle: "Known chat title", attachedCommandState: .idle) == nil,
                "attached presentation hid a non-catch-up catalog condition")
        }
        // Reproduce the production shape: the canonical summary joins by exact Session journal,
        // but the attached Work cursor is ahead, so effective attention and the rail state remain
        // unknown while Work's independently attached projection is still available.
        let railSession = SessionRef("rail-catch-up-session")
        let railSessionJournal = JournalRef.session(
            railSession, journalID: "rail-catch-up-session-journal",
            authority: TimelineAuthorityRef("rail-catch-up-authority"))
        let railWork = WorkRef(workHostID: "rail-catch-up-host", workID: "rail-catch-up-work")
        let railWorkJournal = JournalRef.work(railWork, journalID: "rail-catch-up-work-journal")
        let railAttachment = SessionAttachmentRef("rail-catch-up-attachment")
        let railRequestedCursor = JournalCursor(
            journal: railWorkJournal, eventID: "rail-work-created", sequence: 1)
        var railSessionSnapshot = SessionSnapshot()
        railSessionSnapshot.session = railSession
        railSessionSnapshot.journal = railSessionJournal
        railSessionSnapshot.lifecycle = .active
        railSessionSnapshot.attention = .none
        railSessionSnapshot.lastEventID = "rail-session-attached"
        railSessionSnapshot.lastSequence = 2
        railSessionSnapshot.seenEventIDs = ["rail-session-created", "rail-session-attached"]
        railSessionSnapshot.messages = [SessionMessageSnapshot(
            eventID: "rail-session-message", role: "user", text: "Known chat title")]
        railSessionSnapshot.attachments[railAttachment.attachmentID] = SessionAttachmentSnapshot(
            attachment: railAttachment, work: railWork, cursor: railRequestedCursor)
        var railWorkSnapshot = WorkSnapshot()
        railWorkSnapshot.journal = railWorkJournal
        railWorkSnapshot.work = railWork
        railWorkSnapshot.workHost = WorkHostRef(railWork.workHostID)
        railWorkSnapshot.lifecycle = .active
        railWorkSnapshot.execution = .running
        railWorkSnapshot.lastEventID = "rail-work-attached"
        railWorkSnapshot.lastSequence = 2
        railWorkSnapshot.eventSequences = ["rail-work-created": 1, "rail-work-attached": 2]
        let railActor = TimelineActor(actorID: "rail-catch-up-probe", kind: "test")
        let railSessionCreated = TimelineEvent(
            eventID: "rail-session-created", journal: railSessionJournal, sequence: 1,
            session: railSession, actor: railActor, hostRecordedAt: Date(timeIntervalSince1970: 1),
            type: "session.created")
        let railSessionAttached = TimelineEvent(
            eventID: "rail-session-attached", journal: railSessionJournal, sequence: 2,
            previousEventID: "rail-session-created", session: railSession, work: railWork,
            sessionAttachment: railAttachment, actor: railActor,
            hostRecordedAt: Date(timeIntervalSince1970: 2), type: "session.attached")
        let railWorkCreated = TimelineEvent(
            eventID: "rail-work-created", journal: railWorkJournal, sequence: 1,
            work: railWork, workHost: WorkHostRef(railWork.workHostID), actor: railActor,
            hostRecordedAt: Date(timeIntervalSince1970: 1), type: "work.created")
        let railWorkAttached = TimelineEvent(
            eventID: "rail-work-attached", journal: railWorkJournal, sequence: 2,
            previousEventID: "rail-work-created", session: railSession, work: railWork,
            workHost: WorkHostRef(railWork.workHostID),
            sessionAttachment: railAttachment, actor: railActor,
            hostRecordedAt: Date(timeIntervalSince1970: 2), type: "session.attached")
        func railRecord(_ event: TimelineEvent, byteStart: Int) throws -> TimelineJournalRecord {
            var bytes = try JSONEncoder().encode(event)
            bytes.append(0x0A)
            return TimelineJournalRecord(
                event: event, rawLineBytes: bytes, byteStart: byteStart,
                byteEnd: byteStart + bytes.count)
        }
        func railRead(_ events: [TimelineEvent]) throws -> TimelineJournalReadResult {
            var offset = 0
            var records: [TimelineJournalRecord] = []
            for event in events {
                let record = try railRecord(event, byteStart: offset)
                records.append(record)
                offset = record.byteEnd
            }
            return TimelineJournalReadResult(records: records)
        }
        guard let railSummary = SessionCatalogCanonicalAdapter.summarize(
            session: railSessionSnapshot, works: [railWorkSnapshot],
            cursors: [railAttachment.attachmentID: railRequestedCursor],
            sessionRead: try railRead([railSessionCreated, railSessionAttached]),
            workReads: [railWorkJournal: try railRead([railWorkCreated, railWorkAttached])]) else {
            throw Failure.assertion("rail catch-up fixture did not produce a canonical summary")
        }
        let railProjection = CanonicalAttentionInboxProjection(summary: railSummary)
            .workspaceRail(summaries: [railSummary])
        guard let railEntry = railProjection.entries.first else {
            throw Failure.assertion("rail catch-up fixture did not produce a rail entry")
        }
        try require(
            railEntry.join == .exact && !railEntry.isKnown && railEntry.state == .unknown
                && railEntry.workEvidence.count == 1,
            "Work cursor lag did not produce the exact unknown rail shape")
        try require(CanonicalWorkspaceRailPresentation.attachedFallback(
            entryIsKnown: railEntry.isKnown, entryJoin: railEntry.join,
            attachedServiceBacked: true, attachedProjectionIsCanonical: true,
            attachedTitle: "Known chat title", attachedCommandState: .running) != nil,
                    "exact unknown rail shape discarded attached presentation identity")
        for flags in [(true, true, true), (false, false, true), (false, true, false)] {
            try require(CanonicalWorkspaceRailPresentation.attachedFallback(
                entryIsKnown: flags.0, entryJoin: .incomplete,
                attachedServiceBacked: flags.1, attachedProjectionIsCanonical: flags.2,
                attachedTitle: "Known chat title", attachedCommandState: .idle) == nil,
                "attached presentation replaced known state or used an unverified attachment")
        }
        for title: String? in [nil, "", "   ", "New run"] {
            try require(CanonicalWorkspaceRailPresentation.attachedFallback(
                entryIsKnown: false, entryJoin: .incomplete,
                attachedServiceBacked: true, attachedProjectionIsCanonical: true,
                attachedTitle: title, attachedCommandState: .idle) == nil,
                "ambiguous or placeholder attachment invented a title")
        }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "aviary-chat-journey-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await runProjectReconfirmationProbe(root: root)
        let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        let model = AppModel(home: home)
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

        let reopened = AppModel(home: home)
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
        let failedSave = AppModel(home: AgentHome(root: unavailableRoot))
        try require(!failedSave.createPendingChat(cwd: root.path, providerID: nil, modelID: nil,
                                                 prompt: "keep this in the editor"), "save failure claimed success")
        try require(failedSave.pendingChats.isEmpty && failedSave.pendingChatStoreError != nil,
                    "save failure missing visible explanation")

        try await runServiceInitialStartProbe(root: root)
        try await ConsumerTelemetryProbe.run(root: root)
    }
}
