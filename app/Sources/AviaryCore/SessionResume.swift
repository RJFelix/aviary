import Foundation

/// What replaying a session's transcript produced, and what it had to change to be sendable.
///
/// The counts are not diagnostics for their own sake. A resumed conversation that quietly
/// differs from the recorded one is the worst failure this feature has, because the model
/// behaves oddly and the transcript looks fine — so every departure from the file is counted
/// and surfaced.
public struct SessionReplay: Sendable {
    /// Prior turns, in wire order, with **no system message** — the agent supplies its own,
    /// freshly built from the current skills and context files.
    public var messages: [ChatMessage] = []
    /// True when history was cut at a compaction marker, so the model is resuming from a
    /// summary rather than the full record.
    public var resumedAfterCompaction = false
    /// Tool calls that never got a result because the run died mid-tool. Each one is given a
    /// synthetic error result, because a call with no result is not a valid request.
    public var synthesizedToolResults = 0
    /// Results whose call lived on a pruned branch. Dropped: a result with no call is not a
    /// valid request either, and inventing the call would invent what was run.
    public var droppedOrphanResults = 0
    /// Entries that carry no model-visible content — notes, state changes, extension rows.
    public var skippedEntries = 0
    /// Visible reasoning blocks dropped. See the note in `replay` on why these cannot be sent.
    public var droppedThinkingBlocks = 0
    public var lastModel: String?
    public var lastProvider: String?

    public var isEmpty: Bool { messages.isEmpty }

    /// One line for a banner. Nil when the replay was clean, so a clean resume says nothing.
    public var caveat: String? {
        var parts: [String] = []
        if resumedAfterCompaction { parts.append("resuming from a compaction summary") }
        if synthesizedToolResults > 0 {
            parts.append("\(synthesizedToolResults) unfinished tool "
                + (synthesizedToolResults == 1 ? "call" : "calls") + " marked as interrupted")
        }
        if droppedOrphanResults > 0 {
            parts.append("\(droppedOrphanResults) orphaned tool "
                + (droppedOrphanResults == 1 ? "result" : "results") + " dropped")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Turns replayed, for a "picked up N turns" line.
    public var turnCount: Int {
        messages.filter { $0.role == .user || $0.role == .assistant }.count
    }
}

public enum SessionResume {
    /// Rebuild a sendable conversation from a session file.
    public static func replay(fileURL: URL) -> SessionReplay? {
        guard let transcript = SessionParser.parse(fileURL: fileURL) else { return nil }
        return replay(transcript)
    }

    /// Rebuild a sendable conversation from a parsed transcript.
    ///
    /// Deliberately built on `SessionParser` rather than re-reading the JSONL. The parser
    /// already decides which branch is live — a session is a tree, and the file contains every
    /// conversation the session ever had — and going through it means **what gets replayed is
    /// exactly what the transcript shows**. A second reader would eventually disagree with the
    /// screen, and that disagreement would be invisible.
    public static func replay(_ transcript: Transcript) -> SessionReplay {
        var out = SessionReplay()
        out.lastModel = transcript.lastModel
        out.lastProvider = transcript.lastProvider

        // The first user turn, kept across a compaction. In-process compaction keeps
        // `[system, first task]` and summarises only the middle, so replay has to keep the
        // same two things or a resumed run's history differs in shape from a run that
        // compacted while it was alive.
        var firstUserMessage: ChatMessage?

        for item in transcript.items {
            switch item.kind {
            case .user, .agentMessage:
                // An agent message is a message *to* this agent, which is the user role on
                // the wire regardless of who sent it.
                let content = wireContent(item.blocks, replay: &out)
                let message = ChatMessage(
                    role: .user,
                    content: content.isEmpty ? [.text(item.plainText)] : content)
                if firstUserMessage == nil { firstUserMessage = message }
                out.messages.append(message)

            case .assistant:
                // Tool calls stay attached to the assistant turn that made them; the parser
                // also emits a separate `.tool` row per call, which is where the result goes.
                let content = wireContent(item.blocks, replay: &out)
                // An assistant turn with nothing left after dropping thinking is not worth
                // sending, and an empty assistant message is rejected by some routes.
                if !content.isEmpty {
                    out.messages.append(ChatMessage(role: .assistant, content: content))
                }

            case .tool:
                guard let call = item.toolCall else { out.skippedEntries += 1; continue }
                // A synthetic `tool:` id means the parser paired this row with a call it saw.
                // Any other id is an orphan whose call was pruned with its branch.
                guard item.id == "tool:\(call.id)" else {
                    out.droppedOrphanResults += 1
                    continue
                }
                if let text = item.toolResultText {
                    // An empty string is a legitimately empty result; only `nil` means no
                    // result entry was ever written.
                    out.messages.append(ChatMessage(role: .tool, content: [
                        .toolResult(id: call.id, name: call.name, text: text,
                                    isError: item.toolIsError),
                    ]))
                } else {
                    out.synthesizedToolResults += 1
                    out.messages.append(ChatMessage(role: .tool, content: [
                        .toolResult(
                            id: call.id, name: call.name,
                            text: "[No result recorded — the previous run ended before this "
                                + "tool returned.]",
                            isError: true),
                    ]))
                }

            case .compaction:
                // Everything before the marker is superseded. Reproduces the in-process shape
                // exactly: first task, then the summary as a user turn, then the tail.
                let summary = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !summary.isEmpty else { out.skippedEntries += 1; continue }
                out.resumedAfterCompaction = true
                out.messages = (firstUserMessage.map { [$0] } ?? [])
                    + [ChatMessage(role: .user, content: [
                        .text("[Earlier work, compacted]\n\n" + summary),
                    ])]
                // Departures before the cut no longer describe what is being sent.
                out.synthesizedToolResults = 0
                out.droppedOrphanResults = 0

            case .bash, .custom, .note, .stateChange, .branchSummary:
                // No model-visible content, or content whose wire shape this replay would have
                // to invent. Counted rather than silently ignored.
                out.skippedEntries += 1
            }
        }

        // A conversation may not end on an unanswered call even if the file does.
        return out
    }

    /// Map display blocks onto wire content.
    ///
    /// Visible reasoning is dropped. It cannot be replayed faithfully: the routes that return
    /// it want their own encrypted form echoed back — Codex sends
    /// `reasoning.encrypted_content`, which is deliberately not persisted — and sending the
    /// human-readable summary in its place is not the same thing. Dropping it costs the model
    /// its earlier train of thought; sending a re-description would be a quiet lie about what
    /// it previously thought.
    private static func wireContent(
        _ blocks: [ContentBlock], replay out: inout SessionReplay
    ) -> [ChatContent] {
        var content: [ChatContent] = []
        for block in blocks {
            switch block {
            case .text(let text):
                if !text.isEmpty { content.append(.text(text)) }
            case .thinking:
                out.droppedThinkingBlocks += 1
            case .toolCall(let call):
                content.append(.toolCall(id: call.id, name: call.name, arguments: call.arguments))
            case .image(let mime, let data):
                content.append(.image(mimeType: mime, base64: data))
            }
        }
        return content
    }
}
