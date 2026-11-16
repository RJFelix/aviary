import Foundation
import AviaryCore

/// Opt-in account-backed proof through AppModel, LiveRun, driver, MSP, and the cold parser.
/// Does not bootstrap the service, inspect other chats, or read Muse credential files.
enum MuseChatProbe {
    @MainActor static func runIfRequested() {
        guard CommandLine.arguments.contains("--muse-chat-probe")
            || CommandLine.arguments.contains("--muse-controls-probe")
            || CommandLine.arguments.contains("--muse-resume-probe") else { return }
        let done = Atomic(false)
        Task { @MainActor in
            do {
                try await check()
                print("Muse chat: start, answer, follow-up, cold transcript, End PASS")
                done.set(true)
            } catch {
                FileHandle.standardError.write(Data("Muse chat probe failed: \(error)\n".utf8))
                exit(1)
            }
        }
        while !done.get() {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        exit(0)
    }

    private enum Failure: Error { case check(String) }

    @MainActor private static func check() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aviary-muse-chat-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let home = AgentHome(root: root.appendingPathComponent("home", isDirectory: true))
        let app = AppModel(home: home)
        let prompt = "Reply with exactly MUSE_READY. Do not use tools."
        guard app.startMuseCodeRun(cwd: workspace.path, model: "muse-spark-1.2",
                                   effort: "low", prompt: prompt),
              let run = app.runs.last, run.isMuseCode, !run.isServiceBacked else {
            throw Failure.check("Muse did not create the expected driven chat")
        }
        do {
            try await settle(run, expected: "MUSE_READY")
            let result = await run.send("What exact marker did you just reply with? Reply only with that marker.")
            guard result.wasHandedOff else { throw Failure.check("follow-up not delivered") }
            try await settle(run, expected: "MUSE_READY", minimumAssistantRows: 2)
            guard let path = run.sessionFile,
                  let parsed = SessionParser.parse(fileURL: URL(fileURLWithPath: path)),
                  parsed.items.filter({ $0.kind == .user }).count == 2,
                  parsed.items.filter({ $0.kind == .assistant && $0.plainText.contains("MUSE_READY") }).count >= 2,
                  parsed.usage.totalTokens > 0,
                  parsed.usage.completeness.cost == .unavailable else {
                throw Failure.check("cold transcript did not preserve both exchanges")
            }
            if CommandLine.arguments.contains("--muse-controls-probe") {
                let tool = await run.send("Use the shell tool to run exactly: printf 'MUSE_TOOL_OK\\n'. Then reply with exactly MUSE_TOOL_OK.")
                guard tool.wasHandedOff else { throw Failure.check("tool request not delivered") }
                try await settle(run, expected: "MUSE_TOOL_OK")
                guard run.items.contains(where: { $0.kind == .tool && ($0.toolResultText ?? "").contains("MUSE_TOOL_OK") }) else {
                    throw Failure.check("tool result not retained as a tool row")
                }
                let long = await run.send("Without tools, write a numbered list of 5000 distinct testing ideas. Do not stop early.")
                guard long.wasHandedOff else { throw Failure.check("cancellation target not delivered") }
                let cancelled = await run.cancel(.agentLoop)
                guard cancelled.wasHandedOff else { throw Failure.check("cancel not delivered") }
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline {
                    if let error = run.errorBanner { throw Failure.check(error) }
                    if let transcript = SessionParser.parse(fileURL: URL(fileURLWithPath: path)),
                       transcript.outcome?.state == .cancelled,
                       !run.isStreaming, run.commandState == .idle { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard SessionParser.parse(fileURL: URL(fileURLWithPath: path))?.outcome?.state == .cancelled else {
                    throw Failure.check("Muse did not confirm cancellation")
                }
                let after = await run.send("Reply with exactly MUSE_AFTER_CANCEL. Do not use tools.")
                guard after.wasHandedOff else { throw Failure.check("follow-up after cancel not delivered") }
                try await settle(run, expected: "MUSE_AFTER_CANCEL")
                guard SessionParser.parse(fileURL: URL(fileURLWithPath: path))?.outcome == nil else {
                    throw Failure.check("cancelled outcome leaked into next turn")
                }
                print("Muse controls: real shell output, confirmed cancellation, post-cancel follow-up PASS")
            }
            await run.stop()
            guard run.hasExited else { throw Failure.check("End did not settle") }
            if CommandLine.arguments.contains("--muse-resume-probe") {
                guard let sessionID = run.sessionID else { throw Failure.check("missing session") }
                let saved = try MuseWorkerClient.load(home: home, sessionID: sessionID)
                let deadline = Date().addingTimeInterval(15)
                while saved.isOwned && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
                guard !saved.isOwned else { throw Failure.check("End did not release ownership") }
                let resumed = AppModel(home: home)
                resumed.resumeMuseSession(sessionID)
                guard let continued = resumed.runs.last else { throw Failure.check("resume did not attach") }
                do {
                    try await settle(continued, expected: "MUSE_READY", minimumAssistantRows: 2)
                    let native = try MuseWorkerClient.load(home: home, sessionID: sessionID)
                    guard native.manifest.museSessionID == saved.manifest.museSessionID,
                          native.manifest.instanceID != saved.manifest.instanceID else {
                        throw Failure.check("resume did not preserve native identity in new generation")
                    }
                    let receipt = await continued.send("What exact marker was used earlier in our conversation? Reply only with that marker. Do not use tools.")
                    guard receipt.wasHandedOff else { throw Failure.check("resumed follow-up not handed off") }
                    try await settle(continued, expected: "MUSE_READY", minimumAssistantRows: 3)
                    continued.setDraft("UNSENT_MUSE_DRAFT")
                    guard await resumed.stopAllWork(), native.isOwned else { throw Failure.check("GUI quit ended worker") }
                    let reopened = AppModel(home: home)
                    reopened.restoreMuseWorkers()
                    guard let attached = reopened.runs.last, attached.draft == "UNSENT_MUSE_DRAFT" else {
                        throw Failure.check("reattach lost saved draft")
                    }
                    try await settle(attached, expected: "MUSE_READY", minimumAssistantRows: 3)
                    await attached.stop()
                    guard attached.hasExited else { throw Failure.check("reattached End failed") }
                    print("Muse resume: native identity, recalled context, GUI detach/reattach, saved draft PASS")
                } catch { await continued.stop(); throw error }
            }
        } catch {
            await run.stop()
            throw error
        }
    }

    @MainActor private static func settle(
        _ run: LiveRun, expected: String, minimumAssistantRows: Int = 1
    ) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let error = run.errorBanner { throw Failure.check(error) }
            if run.museCode?.pendingApproval != nil {
                throw Failure.check("Muse requested approval; this probe does not auto-approve")
            }
            if run.initialPromptDelivered && !run.isStreaming && run.commandState == .idle
                && run.items.filter({ $0.kind == .assistant && $0.plainText.contains(expected) }).count >= minimumAssistantRows {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure.check("no confirmed matching completion within 120 seconds: delivered=\(run.initialPromptDelivered), streaming=\(run.isStreaming), state=\(run.commandState), rows=\(run.items.count)")
    }
}
