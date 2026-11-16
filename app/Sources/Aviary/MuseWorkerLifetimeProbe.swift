import AviaryCore
import Foundation
import Darwin

/// Two executable invocations prove that a Muse worker outlives the GUI process that launched it.
/// The caller supplies a fresh /tmp/aviary-muse-lifetime-<id> root to the launcher, then passes
/// that same root to an independent checker after the launcher process has exited.
enum MuseWorkerLifetimeProbe {
    private static let marker = "MUSE_LIFETIME_READY"
    private static let model = "muse-spark-1.3"
    private static let timeout: TimeInterval = 120

    private enum Failure: Error, LocalizedError {
        case invalidArguments
        case invalidRoot
        case assertion(String)

        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "Pass exactly one Muse detach mode and its temporary root."
            case .invalidRoot: return "The probe root must be a private /tmp/aviary-muse-lifetime-* directory."
            case .assertion(let message): return message
            }
        }
    }

    private struct Receipt: Codable {
        let sessionID: String
    }

    @MainActor static func runIfRequested() {
        let arguments = CommandLine.arguments
        let launchIndex = arguments.firstIndex(of: "--muse-detach-launch")
        let checkIndex = arguments.firstIndex(of: "--muse-detach-check")
        guard launchIndex != nil || checkIndex != nil else { return }
        let done = Atomic(false)
        Task { @MainActor in
            do {
                guard (launchIndex == nil) != (checkIndex == nil),
                      let index = launchIndex ?? checkIndex,
                      index + 1 < arguments.count else { throw Failure.invalidArguments }
                let root = try validatedRoot(arguments[index + 1], creating: launchIndex != nil)
                let deadline = Date().addingTimeInterval(timeout)
                if launchIndex != nil {
                    try await launch(root: root, deadline: deadline)
                    print("Muse lifetime launcher: worker owned after GUI shutdown PASS")
                } else {
                    try await check(root: root, deadline: deadline)
                    print("Muse lifetime checker: parent exit, retained turn, follow-up, End PASS")
                }
                done.set(true)
            } catch {
                FileHandle.standardError.write(Data("Muse lifetime probe FAILED: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        while !done.get() {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        exit(0)
    }

    private static func validatedRoot(_ path: String, creating: Bool) throws -> URL {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parent = root.deletingLastPathComponent().path
        guard (parent == "/tmp" || parent == "/private/tmp"),
              root.lastPathComponent.hasPrefix("aviary-muse-lifetime-"),
              root.lastPathComponent.count > "aviary-muse-lifetime-".count else {
            throw Failure.invalidRoot
        }
        var info = stat()
        let exists = root.path.withCString { lstat($0, &info) } == 0
        if creating {
            guard !exists, errno == ENOENT else { throw Failure.invalidRoot }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            guard root.path.withCString({ lstat($0, &info) }) == 0 else { throw Failure.invalidRoot }
        } else {
            guard exists else { throw Failure.invalidRoot }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o077)) == 0 else { throw Failure.invalidRoot }
        return root
    }

    private static func workspace(_ root: URL) -> URL {
        root.appending(path: "workspace", directoryHint: .isDirectory)
    }

    private static func home(_ root: URL) -> AgentHome {
        AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    }

    private static func receiptURL(_ root: URL) -> URL {
        root.appending(path: "session.json", directoryHint: .notDirectory)
    }

    @MainActor private static func launch(root: URL, deadline: Date) async throws {
        let project = workspace(root)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let agentHome = home(root)
        let app = AppModel(home: agentHome)
        let prompt = "Without using tools, write 120 distinct numbered one-sentence birdwatching tips. "
            + "Finish your reply with exactly \(marker) on its own line."
        guard app.startMuseCodeRun(cwd: project.path, model: model, effort: "low", prompt: prompt),
              let run = app.runs.last, run.isMuseCode, let sessionID = run.sessionID else {
            throw Failure.assertion("The launcher did not create its Muse chat.")
        }
        do {
            let receipt = try JSONEncoder().encode(Receipt(sessionID: sessionID))
            try receipt.write(to: receiptURL(root), options: .atomic)
            var owned: MuseWorkerClient?
            while Date() < deadline {
                if let error = run.errorBanner { throw Failure.assertion(error) }
                if run.museCode?.pendingApproval != nil {
                    throw Failure.assertion("Muse requested approval; the probe will not choose for it.")
                }
                if let client = try? MuseWorkerClient.load(home: agentHome, sessionID: sessionID),
                   client.isOwned { owned = client }
                if run.initialPromptDelivered && run.isStreaming && owned != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let client = owned, run.initialPromptDelivered, run.isStreaming else {
                throw Failure.assertion("Muse did not acknowledge an active first turn before the deadline.")
            }
            guard await app.stopAllWork() else {
                throw Failure.assertion("GUI shutdown refused to preserve the Muse chat.")
            }
            guard client.isOwned else {
                throw Failure.assertion("The worker lost ownership during GUI shutdown.")
            }
        } catch {
            await endOwnWorker(home: agentHome, sessionID: sessionID)
            throw error
        }
    }

    @MainActor private static func check(root: URL, deadline: Date) async throws {
        let agentHome = home(root)
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL(root)))
        let client = try MuseWorkerClient.load(home: agentHome, sessionID: receipt.sessionID)
        guard client.manifest.cwd == workspace(root).path,
              client.manifest.model == model,
              client.manifest.initialPrompt.contains(marker),
              client.isOwned else {
            throw Failure.assertion("The expected Muse worker is not owned by this probe root.")
        }
        let app = AppModel(home: agentHome)
        app.restoreMuseWorkers()
        guard let run = app.runs.first(where: { $0.isMuseCode && $0.sessionID == receipt.sessionID }) else {
            throw Failure.assertion("A new GUI process could not attach to the saved Muse worker.")
        }
        do {
            try await waitForTurn(run, marker: marker, assistantRows: 1, deadline: deadline)
            let result = await run.send("What exact marker ended your previous answer? Reply with only that marker. Do not use tools.")
            guard result.wasHandedOff else {
                throw Failure.assertion("The independent GUI could not hand off its follow-up.")
            }
            try await waitForTurn(run, marker: marker, assistantRows: 2, deadline: deadline)
            await run.stop()
            while client.isOwned && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !client.isOwned else { throw Failure.assertion("End did not release worker ownership.") }
        } catch {
            await endOwnWorker(home: agentHome, sessionID: receipt.sessionID)
            throw error
        }
    }

    @MainActor private static func waitForTurn(
        _ run: LiveRun, marker: String, assistantRows: Int, deadline: Date
    ) async throws {
        while Date() < deadline {
            if let error = run.errorBanner { throw Failure.assertion(error) }
            if run.museCode?.pendingApproval != nil {
                throw Failure.assertion("Muse requested approval; the probe will not choose for it.")
            }
            if run.initialPromptDelivered && !run.isStreaming && run.commandState == .idle,
               run.items.filter({ $0.kind == .assistant && $0.plainText.contains(marker) }).count >= assistantRows {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure.assertion("The expected Muse turn did not complete within 120 seconds.")
    }

    /// Cleanup is confined to the exact session and generation recorded under this probe root.
    private static func endOwnWorker(home: AgentHome, sessionID: String) async {
        guard let client = try? MuseWorkerClient.load(home: home, sessionID: sessionID),
              client.manifest.cwd == workspace(home.root.deletingLastPathComponent()).path,
              client.manifest.model == model, client.manifest.initialPrompt.contains(marker),
              client.isOwned else { return }
        _ = try? await client.request(.init(.end), commandID: UUID().uuidString, timeout: 15)
    }
}
