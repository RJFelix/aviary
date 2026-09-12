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
        case turn
        case review
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
        let model = AppModel(
            home: home, presentationDefaults: defaults,
            modelPreferencesStore: ModelPreferencesStore(
                directory: home.root.appending(path: "model-preferences")))

        var run: LiveRun?
        do {
            guard model.createPendingChat(
                cwd: workspaceURL.path, providerID: providerID, modelID: modelID,
                prompt: prompt, title: "Live telemetry probe")
            else { throw Failure.startup }

            let selectedID = model.selectedPendingChatID
            guard let savedStartID = model.pendingChats.first(where: {
                $0.id == selectedID
            })?.startCommandID else { throw Failure.startup }
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

            let review = await run.loadServiceRepositoryReview(expectedDescriptor: descriptor)
            guard case .success(let observed) = review,
                  observed.status == .changes,
                  observed.runID == activeRun.runID,
                  observed.files.contains(where: { $0.path == "probe-result.txt" })
            else { throw Failure.review }

            let receipt = Receipt(
                work: AviaryTelemetry.workIdentity(work),
                journal: AviaryTelemetry.journalIdentity(journal),
                session: AviaryTelemetry.identity(sessionID),
                run: AviaryTelemetry.identity(activeRun.runID),
                startCommand: AviaryTelemetry.identity(savedStartID),
                action: AviaryTelemetry.identity(pythonAction.action.actionID),
                artifact: AviaryTelemetry.identity(descriptor.artifactID))

            await run.end()
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
        poll: @escaping @MainActor () async throws -> T?
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = try await poll() { return value }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.turn
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
