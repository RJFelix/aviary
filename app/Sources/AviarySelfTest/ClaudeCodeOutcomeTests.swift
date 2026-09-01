import Foundation
@testable import AviaryCore

/// Exercises the real ClaudeCodeRun journal seam rather than manufacturing an outcome marker.
/// The executable registry wires this async case beside the other Phase 0 tests.
enum ClaudeCodeOutcomeSelfTests {
    static func run() async throws {
        try expect(
            ClaudeCodeRun.exitFailure(
                status: 0, pendingTurnResult: false, diagnostics: "") == nil,
            "an idle status-zero exit must remain a clean exit")
        try expect(
            ClaudeCodeRun.exitFailure(
                status: 0, pendingTurnResult: true, diagnostics: "")
                == "Claude Code exited before completing the active turn.",
            "status zero without the pending result frame must be a failure")
        try expect(
            ClaudeCodeRun.exitFailure(
                status: 9, pendingTurnResult: false, diagnostics: "signal")?
                .contains("status 9: signal") == true,
            "a nonzero idle crash must remain a durable failure")

        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "aviary-claude-outcome-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let run = try ClaudeCodeRun(
            settings: .init(
                home: AgentHome(root: root), cwd: "/tmp", model: "sonnet",
                systemPrompt: "", bridgeExecutable: "/tmp/aviary-test-bridge"),
            bridge: KernelBridge())

        let markerID = try expect(
            await run.recordOutcome(.failed, detail: "Claude result failed"),
            "the real ClaudeCodeRun seam must return a durable marker id")
        try expect(
            await run.recordOutcome(.cancelled, detail: "late stop") == nil,
            "a later stop must not append a competing terminal marker")
        await run.stop()

        let transcript = try expect(
            SessionParser.parse(fileURL: run.fileURL),
            "the run journal must remain cold-readable after teardown")
        try expect(transcript.outcome?.id == markerID, "reload must identify the writer marker")
        try expect(transcript.outcome?.state == .failed, "reload must preserve failure state")
        try expect(transcript.outcome?.detail == "Claude result failed",
                   "reload must preserve bounded failure detail")

        let idleRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "aviary-claude-idle-outcome-\(UUID().uuidString)",
                directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: idleRoot) }
        let idleRun = try ClaudeCodeRun(
            settings: .init(
                home: AgentHome(root: idleRoot), cwd: "/tmp", model: "sonnet",
                systemPrompt: "", bridgeExecutable: "/tmp/aviary-test-bridge"),
            bridge: KernelBridge())
        await idleRun.stop()
        let idleTranscript = try expect(
            SessionParser.parse(fileURL: idleRun.fileURL),
            "an idle run must remain cold-readable after teardown")
        try expect(idleTranscript.outcome == nil,
                   "ending an idle run must not fabricate a cancellation outcome")
    }

    private static func expect<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
