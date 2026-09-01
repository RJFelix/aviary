import Foundation
@testable import AviaryCore

/// Focused self-tests for the Phase 0 live transcript seam.
///
/// `main.swift` owns the executable's case registry.  Keeping these tests in their own file
/// lets the registry be wired in alongside the driver adapter work without making this core
/// change depend on either UI driver.  The tests are intentionally plain throwing functions so
/// they work with Aviary's XCTest-free self-test harness.
enum LiveTranscriptOverlaySelfTests {
    static func run() throws {
        try repeatedUpdatesReplaceOneRow()
        try durableReloadCollapsesLiveRow()
        try explicitCommitMappingCollapsesLegacyID()
        try repeatedCommitAcknowledgementIsIdempotent()
        try lifecycleOnlyCancellationRetainsPartialRow()
        try durableOutcomeConvergesTerminalPartialRowToColdProjection()
        try terminalLifecycleCannotReopenIdentity()
        try replayedUnnumberedContentIsIdempotent()
        try cumulativeTextAndThinkingUpdatesStayOneRow()
        try staleRevisionCannotRollBackStream()
        try durableFailureAndCancellationSurviveColdReload()
        try durableOutcomeResetsOnNewInput()
    }

    private static func repeatedUpdatesReplaceOneRow() throws {
        let overlay = LiveTranscriptOverlay()
        let first = item(id: "message-1", text: "hel")
        let second = item(id: "message-1", text: "hello")

        _ = overlay.apply(turnID: "turn-1", messageID: "message-1", item: first, lifecycle: .streaming, revision: 1)
        _ = overlay.apply(turnID: "turn-1", messageID: "message-1", item: second, lifecycle: .completed, revision: 2)
        let snapshot = overlay.apply(turnID: "turn-1", messageID: "message-1", item: second, lifecycle: .completed, revision: 2)
        try expect(snapshot.items.count == 1, "repeated callbacks must not append transcript rows")
        try expect(snapshot.items.first?.plainText == "hello", "latest callback must replace the streamed value")
        try expect(snapshot.live.count == 1 && snapshot.live[0].lifecycle == .completed,
                   "terminal state remains visible until durable reconciliation")
    }

    private static func durableReloadCollapsesLiveRow() throws {
        let overlay = LiveTranscriptOverlay()
        _ = overlay.apply(turnID: "turn-1", messageID: "provider-message", item: item(id: "live-row", text: "done"), lifecycle: .completed)

        // The legacy writer uses a different event ID.  Matching the stable message ID still
        // removes the ephemeral row once the parser sees the committed entry.
        let snapshot = overlay.reconcile(committed: [item(id: "provider-message", text: "done")])
        try expect(snapshot.live.isEmpty, "reload must remove a live row proven durable by message ID")
        try expect(snapshot.items.count == 1 && snapshot.items[0].id == "provider-message",
                   "durable row must remain as the sole rendered item")
    }

    private static func lifecycleOnlyCancellationRetainsPartialRow() throws {
        let overlay = LiveTranscriptOverlay()
        _ = overlay.apply(turnID: "turn-1", messageID: "message-1", item: item(id: "message-1", text: "partial"), lifecycle: .streaming)
        let snapshot = overlay.apply(turnID: "turn-1", messageID: "message-1", lifecycle: .cancelled)
        try expect(snapshot.items.map(\.plainText) == ["partial"],
                   "a cancellation without a row must retain the partial streamed row")
        try expect(snapshot.lifecycle(for: LiveTranscriptIdentity(turnID: "turn-1", messageID: "message-1")) == .cancelled,
                   "cancellation is exposed as state rather than a synthetic note row")
    }

    private static func durableOutcomeConvergesTerminalPartialRowToColdProjection() throws {
        let overlay = LiveTranscriptOverlay()
        let identity = LiveTranscriptIdentity(turnID: "turn-1", messageID: "message-1")
        _ = overlay.apply(
            turnID: identity.turnID.rawValue, messageID: identity.messageID.rawValue,
            item: item(id: "message-1", text: "partial"), lifecycle: .cancelled)

        // This is the two-step adapter crossing: ordinary durable rows reconcile first; the
        // separately durable outcome proves that a terminal partial row has no cold-row peer.
        let jsonl = """
        {"type":"session","id":"s1","version":1,"timestamp":"2026-08-31T10:00:00Z","cwd":"/tmp"}
        {"type":"custom_message","id":"outcome-1","parentId":"s1","timestamp":"2026-08-31T10:00:01Z","customType":"aviary.outcome","outcomeState":"cancelled","detail":"stopped"}
        """
        let cold = try expect(
            SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"),
            "the durable outcome fixture must cold-parse")
        _ = overlay.reconcile(committed: cold.items)
        if cold.outcome != nil { _ = overlay.remove(identity: identity) }

        try expect(overlay.snapshot.live.isEmpty,
                   "a cold-readable outcome must retire its terminal live-only row")
        try expect(overlay.snapshot.items == cold.items,
                   "the live snapshot must equal the cold projection after outcome reconciliation")
    }

    private static func explicitCommitMappingCollapsesLegacyID() throws {
        let overlay = LiveTranscriptOverlay()
        let identity = LiveTranscriptIdentity(turnID: "turn-1", messageID: "provider-message")
        _ = overlay.apply(LiveTranscriptDelta(
            identity: identity,
            item: item(id: "live-row", text: "done"),
            lifecycle: .completed))

        let snapshot = overlay.commit(identity: identity, committedItem: item(id: "writer-event-7", text: "done"))
        try expect(snapshot.live.isEmpty, "writer acknowledgement must remove the mapped live row")
        try expect(snapshot.items.count == 1 && snapshot.items[0].id == "writer-event-7",
                   "a legacy writer ID must not create a second rendered row")
    }

    private static func cumulativeTextAndThinkingUpdatesStayOneRow() throws {
        let overlay = LiveTranscriptOverlay()
        _ = overlay.apply(turnID: "turn-1", messageID: "message-1", content: .thinking("plan "), lifecycle: .streaming, revision: 1)
        _ = overlay.apply(turnID: "turn-1", messageID: "message-1", content: .thinking("step"), lifecycle: .streaming, revision: 2)
        _ = overlay.apply(turnID: "turn-1", messageID: "message-1", content: .text("answer"), lifecycle: .completed, revision: 3)

        let snapshot = overlay.snapshot
        try expect(snapshot.items.count == 1, "content deltas must accumulate into one stable row")
        try expect(snapshot.items[0].blocks == [.thinking("plan step"), .text("answer")],
                   "text and thinking deltas must preserve typed block boundaries")
    }

    private static func repeatedCommitAcknowledgementIsIdempotent() throws {
        let overlay = LiveTranscriptOverlay()
        let identity = LiveTranscriptIdentity(turnID: "turn-1", messageID: "provider-message")
        _ = overlay.apply(LiveTranscriptDelta(identity: identity, item: item(id: "live-row", text: "done"), lifecycle: .completed))
        let committed = item(id: "writer-event-7", text: "done")
        _ = overlay.commit(identity: identity, committedItem: committed)
        let snapshot = overlay.commit(identity: identity, committedItem: committed)
        try expect(snapshot.live.isEmpty, "repeated writer acknowledgements must keep the overlay closed")
        try expect(snapshot.items.count == 1, "repeated writer acknowledgements must not duplicate the durable row")
    }

    private static func terminalLifecycleCannotReopenIdentity() throws {
        let overlay = LiveTranscriptOverlay()
        _ = overlay.apply(turnID: "turn-1", messageID: "message-1", item: item(id: "message-1", text: "partial"), lifecycle: .cancelled, revision: 2)
        let snapshot = overlay.apply(turnID: "turn-1", messageID: "message-1", content: .text("late"), lifecycle: .streaming, revision: 3)
        try expect(snapshot.lifecycle(for: LiveTranscriptIdentity(turnID: "turn-1", messageID: "message-1")) == .cancelled,
                   "a late streaming callback must not reopen a cancelled identity")
        try expect(snapshot.items.first?.plainText == "partial",
                   "a late callback must not mutate a terminal partial row")
    }

    private static func replayedUnnumberedContentIsIdempotent() throws {
        let overlay = LiveTranscriptOverlay()
        let delta = LiveTranscriptDelta(
            turnID: "turn-1", messageID: "message-1", content: .text("same"), lifecycle: .streaming)
        _ = overlay.apply(delta)
        let snapshot = overlay.apply(delta)
        try expect(snapshot.items.count == 1 && snapshot.items[0].plainText == "same",
                   "replayed unnumbered content must not append twice")
    }

    private static func staleRevisionCannotRollBackStream() throws {
        let overlay = LiveTranscriptOverlay()
        _ = overlay.apply(turnID: "turn-1", messageID: "message-1", item: item(id: "message-1", text: "new"), lifecycle: .streaming, revision: 2)
        let snapshot = overlay.apply(turnID: "turn-1", messageID: "message-1", item: item(id: "message-1", text: "old"), lifecycle: .streaming, revision: 1)
        try expect(snapshot.items.first?.plainText == "new", "older provider callbacks must not roll back visible text")
    }

    private static func durableFailureAndCancellationSurviveColdReload() throws {
        for state in ["failed", "cancelled"] {
            let jsonl = """
            {"type":"session","id":"s1","version":1,"timestamp":"2026-08-31T10:00:00Z","cwd":"/tmp"}
            {"type":"custom_message","id":"outcome-1","parentId":"s1","timestamp":"2026-08-31T10:00:01Z","customType":"aviary.outcome","outcomeState":"\(state)","detail":"provider boundary","content":[{"type":"text","text":"provider boundary"}]}
            {"type":"message","id":"truncated
            """
            let transcript = SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1")
            try expect(transcript?.outcome?.state.rawValue == state,
                       "\(state) outcome must survive cold reload")
            try expect(transcript?.outcome?.detail == "provider boundary",
                       "\(state) outcome detail must be retained")
            try expect(transcript?.unparsedLines == 1,
                       "a truncated tail must be reported without hiding the durable outcome")
            try expect(transcript?.items.isEmpty == true,
                       "terminal outcome must not fabricate a transcript message row")
        }
    }

    private static func durableOutcomeResetsOnNewInput() throws {
        let jsonl = """
        {"type":"session","id":"s1","version":1,"timestamp":"2026-08-31T10:00:00Z","cwd":"/tmp"}
        {"type":"custom_message","id":"outcome-1","parentId":"s1","timestamp":"2026-08-31T10:00:01Z","customType":"aviary.outcome","outcomeState":"failed","detail":"provider boundary"}
        {"type":"message","id":"user-1","parentId":"outcome-1","timestamp":"2026-08-31T10:00:02Z","message":{"role":"user","content":[{"type":"text","text":"try again"}]}}
        """
        let transcript = SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1")
        try expect(transcript?.outcome == nil,
                   "a new user input must clear the prior terminal outcome")
        try expect(transcript?.items.last?.plainText == "try again",
                   "the retrying user message must remain visible")
    }

    private static func item(id: String, text: String) -> TranscriptItem {
        var result = TranscriptItem(id: id, kind: .assistant, timestamp: Date(timeIntervalSince1970: 0))
        result.blocks = [.text(text)]
        return result
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private static func expect<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message) }
        return value
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}
