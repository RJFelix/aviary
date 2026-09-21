import AviaryCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs one bounded, disposable conversation through the same AppModel and daemon path as the
/// GUI. The companion verifier owns the loopback provider, OTLP collector, temporary home, and
/// process cleanup; this entry point never reads the user's configured home or credentials.
enum LiveChatTelemetryProbe {
    private static let argument = "--live-chat-telemetry-probe"
    private static let homeVariable = "AVIARY_LIVE_CHAT_PROBE_HOME"
    private static let workspaceVariable = "AVIARY_LIVE_CHAT_PROBE_WORKSPACE"
    private static let providerID = "live-local"
    private static let modelID = "live-model"
    private static let prompt = "LIVE_CHAT_PROMPT_SENTINEL_7f23"
    private static let assistantText = "LIVE_CHAT_ASSISTANT_SENTINEL_18ac"
    private static let directCommandSourceSentinel =
        "LIVE_DIRECT_COMMAND_SOURCE_SENTINEL_c741"
    private static let directCommandOutputSentinel =
        "LIVE_DIRECT_COMMAND_OUTPUT_SENTINEL_a29e"

    private enum Failure: String, Error {
        case invalidEnvironment = "invalid_environment"
        case startup
        case startupHost
        case startupWorkspace
        case startupProvider
        case startupAuthorization
        case startupRequest
        case startupStatusSave
        case startupSavedRowUnreadable
        case startupPresentation
        case turn
        case review
        case directCommand
        case ending
        case shutdown
    }

    private struct Receipt: Codable {
        let work: String
        let journal: String
        let session: String
        let run: String
        let startCommand: String
        let action: String
        let artifact: String
        let directCommand: String
        let directAction: String
    }

    @MainActor static func runIfRequested() {
        guard CommandLine.arguments.contains(argument) else { return }
        let done = Atomic(false)
        Task { @MainActor in
            do {
                let receipt = try await run()
                await AviaryTelemetry.shutdown(maximumDuration: 2)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(receipt), data.count <= 2_048 else {
                    throw Failure.shutdown
                }
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                done.set(true)
            } catch {
                await AviaryTelemetry.shutdown(maximumDuration: 2)
                // Errors on this path can contain provider bodies and local paths. Keep the
                // subprocess receipt fixed and let the canonical/collector assertions identify
                // which bounded stage failed.
                let stage = (error as? Failure)?.rawValue ?? "unknown"
                FileHandle.standardError.write(
                    Data("live chat telemetry probe FAILED:\(stage)\n".utf8))
                exit(1)
            }
        }
        while !done.get() {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        exit(0)
    }

    @MainActor private static func run() async throws -> Receipt {
        let environment = ProcessInfo.processInfo.environment
        guard let homePath = environment[homeVariable],
              let workspacePath = environment[workspaceVariable]
        else { throw Failure.invalidEnvironment }
        let homeURL = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        let workspaceURL = URL(
            fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard try isPrivateFixtureDirectory(homeURL),
              try isPrivateFixtureDirectory(workspaceURL),
              homeURL.deletingLastPathComponent() == workspaceURL.deletingLastPathComponent(),
              homeURL.deletingLastPathComponent().lastPathComponent.hasPrefix("avlive-")
        else { throw Failure.invalidEnvironment }

        let suite = "aviary.live-chat-probe." + UUID().uuidString.lowercased()
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure.invalidEnvironment
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let home = AgentHome(root: homeURL)
        let recordingDirectory = home.root.appending(path: "configured-request-logs")
        try WireLogDirectoryStore(home: home).select(directory: recordingDirectory)
        let model = AppModel(
            home: home, presentationDefaults: defaults,
            modelPreferencesStore: ModelPreferencesStore(
                directory: home.root.appending(path: "model-preferences")))

        var run: LiveRun?
        do {
            guard model.createPendingChat(
                cwd: workspaceURL.path, providerID: providerID, modelID: modelID,
                prompt: prompt, recordPayloads: true, title: "Live telemetry probe")
            else { throw Failure.startup }

            let selectedID = model.selectedPendingChatID
            guard let savedChat = model.pendingChats.first(where: {
                $0.id == selectedID
            }) else { throw Failure.startup }
            let savedStartID = savedChat.startCommandID
            guard model.showsPendingChatInRail(savedChat, visibleAttachmentKeys: []) else {
                throw Failure.startup
            }
            let started: LiveRun = try await wait(upTo: 30) { () async throws -> LiveRun? in
                if let selectedID,
                   let pending = model.pendingChats.first(where: { $0.id == selectedID }),
                   !model.pendingChatIsPreparing(pending), model.workRuns.isEmpty {
                    if pending.phase == .saved {
                        let inventory = try PendingChatStore(home: home).load()
                        guard inventory.unavailable.isEmpty,
                              inventory.rows.contains(where: { $0.id == pending.id }) else {
                            throw Failure.startupSavedRowUnreadable
                        }
                        throw Failure.startupStatusSave
                    }
                    switch pending.failureKind {
                    case .hostUnavailable: throw Failure.startupHost
                    case .workspaceUnavailable, .workspaceConfirmationRequired:
                        throw Failure.startupWorkspace
                    case .providerUnavailable: throw Failure.startupProvider
                    case .authorizationRequired: throw Failure.startupAuthorization
                    case .invalidRequest, .staleCreate: throw Failure.startupRequest
                    default: throw Failure.startup
                    }
                }
                return model.workRuns.first(where: { $0.isServiceBacked })
            }
            run = started
            let run = started

            let settled = try await wait(upTo: 45) { () async throws -> Bool? in
                await run.refreshService()
                guard let projection = run.serviceProjection else { return nil }
                // An active writer can briefly outrun one paired Work/Session read. Retry that
                // read-only observation rather than converting source incompleteness or a stale
                // presentation banner into a terminal execution claim.
                if projection.isCanonical,
                   projection.workSnapshot.lifecycle != .active
                    || projection.workSnapshot.execution == .failed {
                    throw Failure.turn
                }
                let hasAnswer = run.items.contains {
                    $0.kind == .assistant && $0.plainText.contains(assistantText)
                }
                return projection.isCanonical
                    && projection.descriptor.currentRun != nil
                    && projection.workSnapshot.activeRun != nil
                    && run.commandState == .idle
                    && hasAnswer
                    && run.serviceReviewDescriptor != nil ? true : nil
            }
            guard settled == true,
                  let projection = run.serviceProjection,
                  let activeRun = projection.descriptor.currentRun,
                  let descriptor = run.serviceReviewDescriptor,
                  let pythonAction = projection.workSnapshot.actions.values.first(where: {
                      $0.kind == .python && $0.state == .succeeded
                  }),
                  case let startCommands = projection.workSnapshot.commands.values.filter({
                      $0.commandKind == .start && $0.acceptanceRun == activeRun
                  }),
                  startCommands.count == 1,
                  let startCommand = startCommands.first,
                  startCommand.state == .delivered,
                  startCommand.acceptanceEventRef != nil,
                  startCommand.deliveryEventRef != nil,
                  startCommand.carriesSessionInput == true,
                  startCommand.command.commandID == WorkServiceCommandLedgerIdentity.commandID(
                    client: projection.attachment.client, commandID: savedStartID),
                  projection.sessionSnapshot.messageHistory.filter({
                      $0.role == "user" && $0.text == prompt && $0.run == activeRun
                  }).count == 1,
                  let work = projection.workSnapshot.work,
                  let journal = projection.workSnapshot.journal,
                  let sessionID = run.serviceAttachmentKey?.workSession.session.sessionID
            else { throw Failure.turn }

            // The Run-only polling above does not retire AppModel startup cards. Complete
            // that normal bookkeeping before installing the adversarial two-card fixture.
            await model.refreshServiceWork()
            guard !model.pendingChats.contains(where: { $0.id == savedChat.id }) else {
                throw Failure.startupPresentation
            }

            // Keep a value copy of the saved request after durable cleanup. The actual
            // presentation must collapse its duplicate without relying on store deletion.
            guard let key = run.serviceAttachmentKey else { throw Failure.turn }
            let associatedChat = try savedChat.changing(
                phase: .awaitingAcceptance, createdAssociation: key)
            guard model.pendingChatHasCanonicalDelivery(associatedChat),
                  run.savedStartupPrompt(pendingChat: associatedChat) == nil,
                  !model.showsPendingChatInRail(
                    associatedChat, visibleAttachmentKeys: [key]),
                  model.showsPendingChatInRail(
                    associatedChat, visibleAttachmentKeys: []),
                  model.showsPendingChatInRail(
                    associatedChat, visibleAttachmentKeys: [key, key])
            else { throw Failure.turn }
            model.pendingChatDetails[associatedChat.id] = "Local cleanup still needs attention."
            guard model.showsPendingChatInRail(
                associatedChat, visibleAttachmentKeys: [key]),
                  run.savedStartupPrompt(pendingChat: associatedChat) == nil
            else { throw Failure.turn }
            model.pendingChatDetails.removeValue(forKey: associatedChat.id)
            model.selectedPendingChatID = associatedChat.id
            guard model.showsPendingChatInRail(
                associatedChat, visibleAttachmentKeys: [key]) else { throw Failure.turn }
            model.selectedPendingChatID = nil

            // Exercise the actual retained-card recovery button against an already-adopted
            // run. It must refresh and retire this local marker without starting another turn.
            let retainedCard = try PendingChat(
                prompt: prompt, cwd: workspaceURL.path, phase: .awaitingAcceptance,
                startCommandID: savedStartID, createdAssociation: key)
            try PendingChatStore(home: home).insert(retainedCard)
            model.pendingChats.append(retainedCard)
            let conflictingCard = try PendingChat(
                prompt: "A different unsent request", cwd: workspaceURL.path,
                phase: .awaitingAcceptance, startCommandID: "conflicting-start",
                createdAssociation: key)
            try PendingChatStore(home: home).insert(conflictingCard)
            model.pendingChats.append(conflictingCard)
            await model.refreshServiceWork()
            guard model.pendingChats.contains(where: { $0.id == retainedCard.id }),
                  model.pendingChats.contains(where: { $0.id == conflictingCard.id }),
                  model.showsPendingChatInRail(retainedCard, visibleAttachmentKeys: [key]),
                  model.showsPendingChatInRail(conflictingCard, visibleAttachmentKeys: [key])
            else { throw Failure.startupPresentation }
            // Explicit local dismissal resolves the collision; it never dispatches the
            // unrelated request or changes the original Work's command ledger.
            model.stopTrackingPendingChat(conflictingCard)
            guard !model.pendingChats.contains(where: { $0.id == conflictingCard.id })
            else { throw Failure.startupPresentation }
            model.pendingChatDetails[retainedCard.id] = "Local cleanup still needs attention."
            model.selectedPendingChatID = retainedCard.id
            model.retryPendingChat(retainedCard.id)
            let retired = try await wait(upTo: 30, failure: .startupPresentation) {
                () async throws -> Bool? in
                !model.pendingChats.contains(where: { $0.id == retainedCard.id })
                    && !model.pendingChatIsPreparing(retainedCard) ? true : nil
            }
            guard retired == true,
                  !(try PendingChatStore(home: home).load()).rows.contains(where: {
                    $0.id == retainedCard.id
                  }),
                  run.serviceProjection?.workSnapshot.commands.values.filter({
                    $0.commandKind == .start
                  }).count == 1
            else { throw Failure.startupPresentation }

            run.refreshLocalServiceWireLog(home: home)
            guard let recording = run.wireLogURL,
                  recording.deletingLastPathComponent().path == recordingDirectory.path,
                  recording.lastPathComponent == "run-\(activeRun.runID).jsonl",
                  WireLog.read(url: recording).filter({ $0.kind == .request }).count >= 2
            else { throw Failure.turn }

            let review = await run.loadServiceRepositoryReview(expectedDescriptor: descriptor)
            guard case .success(let observed) = review,
                  observed.status == .changes,
                  observed.runID == activeRun.runID,
                  observed.files.contains(where: { $0.path == "probe-result.txt" })
            else { throw Failure.review }

            let directSource = ": '\(directCommandSourceSentinel)'; "
                + "printf '%s\\n' '\(directCommandOutputSentinel)'"
            guard let directCommand = SuggestedShellCommand.make(
                language: "sh", source: directSource),
                  run.canRunDirectShell,
                  await run.directShell(
                    operation: .run, command: directCommand, expectedRun: activeRun)
            else { throw Failure.directCommand }
            let directEntry = try await wait(
                upTo: 20, failure: .directCommand
            ) { () async throws -> WorkServiceDirectShellEntry? in
                await run.refreshService()
                guard let entry = run.directShellEntries.first(where: {
                    $0.source == Data(directSource.utf8)
                }) else { return nil }
                guard entry.state.isTerminal else { return nil }
                let expectedOutput = Data((directCommandOutputSentinel + "\n").utf8)
                guard entry.state == .succeeded,
                      entry.pendingContext,
                      let result = entry.result,
                      result.status == .exited(exitCode: 0),
                      result.source == Data(directSource.utf8),
                      result.stdout.isComplete,
                      result.stdout.totalByteCount == Int64(expectedOutput.count),
                      result.stdout.omittedByteCount == 0,
                      result.stdout.head + result.stdout.tail == expectedOutput,
                      result.stderr.isComplete,
                      result.stderr.totalByteCount == 0,
                      result.stderr.omittedByteCount == 0,
                      result.stderr.head.isEmpty,
                      result.stderr.tail.isEmpty,
                      entry.artifact?.available == true
                else { throw Failure.directCommand }
                return entry
            }
            // Plain End must not silently strand output awaiting the user's next message.
            await run.end()
            guard run.serviceProjection?.descriptor.currentRun == activeRun,
                  !run.isEnding,
                  run.directShellEntries.contains(where: {
                      $0.action == directEntry.action && $0.pendingContext
                  }) else { throw Failure.directCommand }

            let receipt = Receipt(
                work: AviaryTelemetry.workIdentity(work),
                journal: AviaryTelemetry.journalIdentity(journal),
                session: AviaryTelemetry.identity(sessionID),
                run: AviaryTelemetry.identity(activeRun.runID),
                startCommand: AviaryTelemetry.identity(savedStartID),
                action: AviaryTelemetry.identity(pythonAction.action.actionID),
                artifact: AviaryTelemetry.identity(descriptor.artifactID),
                directCommand: AviaryTelemetry.identity(directEntry.command.commandID),
                directAction: AviaryTelemetry.identity(directEntry.action.actionID))

            // This is the explicit confirmation path. It must durably dismiss the output
            // before End closes the actor, rather than merely hiding the GUI card.
            await run.end(discardPendingCommandOutput: true)
            guard !run.directShellEntries.contains(where: \.pendingContext),
                  run.directShellError == nil else { throw Failure.directCommand }
            guard run.isEnding == (run.serviceProjection?.descriptor.execution == .ending)
            else { throw Failure.ending }
            let ended = try await wait(upTo: 20) { () async throws -> Bool? in
                await run.refreshService(resumeInitialStart: false)
                guard let projection = run.serviceProjection else { return nil }
                if projection.isCanonical,
                   projection.workSnapshot.lifecycle == .destroyed {
                    throw Failure.ending
                }
                return projection.isCanonical
                    && projection.descriptor.currentRun == nil
                    && projection.workSnapshot.activeRun == nil
                    && !run.isEnding
                    && !projection.commandInFlight
                    && projection.pendingCommand == nil ? true : nil
            }
            guard ended == true else { throw Failure.ending }
            guard await model.stopAllWork() else { throw Failure.shutdown }
            return receipt
        } catch {
            // Best effort only: End still requires exact canonical ownership. If it cannot be
            // proved, the verifier keeps the home in place until exact daemon cleanup finishes.
            if let run, run.serviceProjection?.descriptor.currentRun != nil {
                await run.refreshService(resumeInitialStart: false)
                await run.end()
            }
            _ = await model.stopAllWork()
            throw error
        }
    }

    @MainActor private static func wait<T>(
        upTo seconds: TimeInterval,
        failure: Failure = .turn,
        poll: @escaping @MainActor () async throws -> T?
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = try await poll() { return value }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw failure
    }

    private static func isPrivateFixtureDirectory(_ url: URL) throws -> Bool {
        guard url.path.utf8.count <= 1_024,
              url.resolvingSymlinksInPath() == url,
              url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/")
        else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0
        else { return false }
        return true
    }
}
