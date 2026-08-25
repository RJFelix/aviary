import Foundation

/// Builds a renderable transcript from a live RPC event stream.
///
/// Produces the same `TranscriptItem` values the file parser does, so history and a
/// streaming run share one renderer. That is the whole point: a live message should not
/// look subtly different from the same message read back tomorrow.
public final class LiveTranscriptBuilder: @unchecked Sendable {
    public private(set) var items: [TranscriptItem] = []
    public private(set) var usage = Usage()
    public private(set) var isStreaming = false
    public private(set) var isCompacting = false
    public private(set) var queued: (steering: [String], followUps: [String]) = ([], [])
    /// Streaming state: content index → block being appended to.
    private var streamingItemIndex: Int?
    private var toolIndexByCallID: [String: Int] = [:]
    private var toolStartTimes: [String: Date] = [:]
    private let lock = NSLock()

    public init() {}

    /// The current assistant message being streamed, if any.
    public var streamingItem: TranscriptItem? {
        lock.lock(); defer { lock.unlock() }
        guard let i = streamingItemIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    @discardableResult
    public func appendLocalUserMessage(_ text: String) -> TranscriptItem {
        lock.lock(); defer { lock.unlock() }
        var item = TranscriptItem(id: "local-user-\(UUID().uuidString)", kind: .user, timestamp: Date())
        item.blocks = [.text(text)]
        items.append(item)
        return item
    }

    public func appendNote(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        var item = TranscriptItem(id: "note-\(UUID().uuidString)", kind: .note, timestamp: Date())
        item.text = text
        items.append(item)
    }

    /// Fold one RPC message into the transcript. Returns true when the UI should redraw.
    @discardableResult
    public func apply(_ message: RPCMessage) -> Bool {
        switch message {
        case .event(let type, let payload):
            return applyEvent(type: type, payload: payload)
        case .response(_, let command, let success, _, let error):
            if !success, let error {
                appendNote("\(command) failed: \(error)")
                return true
            }
            return false
        case .stderr(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Engine stderr is where the interesting failures live (a 401 naming an
            // unexpanded variable, a version-conflict refusal), so surface it rather
            // than swallowing it — but skip pure progress noise.
            guard !trimmed.isEmpty, trimmed.count > 2 else { return false }
            appendNote(trimmed)
            return true
        case .exited(let code, let stderr):
            lock.lock(); isStreaming = false; lock.unlock()
            if code != 0 {
                let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
                appendNote("Engine exited with code \(code)."
                    + (tail.isEmpty ? "" : "\n\n\(tail)"))
            } else {
                appendNote("Engine exited.")
            }
            return true
        }
    }

    private func applyEvent(type: String, payload: JSONValue) -> Bool {
        switch type {
        case "agent_start":
            lock.lock(); isStreaming = true; lock.unlock()
            return true

        case "agent_end":
            lock.lock(); isStreaming = false; streamingItemIndex = nil; lock.unlock()
            return true

        case "message_start":
            guard payload.path("message.role")?.stringValue == "assistant" else { return false }
            lock.lock()
            var item = TranscriptItem(
                id: "live-assistant-\(items.count)", kind: .assistant, timestamp: Date())
            item.model = payload.path("message.model")?.stringValue
            item.provider = payload.path("message.provider")?.stringValue
            items.append(item)
            streamingItemIndex = items.count - 1
            lock.unlock()
            return true

        case "message_update":
            return applyStreamingDelta(payload)

        case "message_end":
            return applyMessageEnd(payload)

        case "tool_execution_start":
            guard let callID = payload["toolCallId"]?.stringValue else { return false }
            lock.lock(); defer { lock.unlock() }
            toolStartTimes[callID] = Date()
            if let idx = toolIndexByCallID[callID] { _ = idx; return false }
            var item = TranscriptItem(id: "tool:\(callID)", kind: .tool, timestamp: Date())
            item.toolCall = ToolCall(
                id: callID,
                name: payload["toolName"]?.stringValue ?? "tool",
                arguments: payload["args"] ?? .object([:]))
            items.append(item)
            toolIndexByCallID[callID] = items.count - 1
            return true

        case "tool_execution_update":
            guard let callID = payload["toolCallId"]?.stringValue else { return false }
            lock.lock(); defer { lock.unlock() }
            guard let idx = toolIndexByCallID[callID], items.indices.contains(idx) else { return false }
            // partialResult is cumulative, not a delta — replace, don't append.
            let text = (payload.path("partialResult.content")?.arrayValue ?? [])
                .compactMap { $0["text"]?.stringValue }.joined()
            items[idx].toolResultText = Ansi.strip(text)
            return true

        case "tool_execution_end":
            guard let callID = payload["toolCallId"]?.stringValue else { return false }
            lock.lock(); defer { lock.unlock() }
            guard let idx = toolIndexByCallID[callID], items.indices.contains(idx) else { return false }
            let blocks = ContentBlock.parse(payload.path("result.content"))
            items[idx].toolResultText = Ansi.strip(
                blocks.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
                    .joined(separator: "\n"))
            items[idx].toolResultImages = blocks.compactMap { b in
                if case .image(let m, let d) = b {
                    return ToolResultImage(mimeType: m, base64: d)
                } else { return nil }
            }
            items[idx].toolIsError = payload["isError"]?.boolValue ?? false
            items[idx].toolDetails = payload.path("result.details")
            if let started = toolStartTimes[callID] {
                items[idx].toolDuration = Date().timeIntervalSince(started)
            }
            return true

        case "session_action_update":
            lock.lock()
            queued.steering = (payload.path("actions.steering")?.arrayValue ?? [])
                .compactMap(\.stringValue)
            queued.followUps = (payload.path("actions.followUps")?.arrayValue ?? [])
                .compactMap(\.stringValue)
            lock.unlock()
            return true

        case "compaction_start":
            lock.lock(); isCompacting = true; lock.unlock()
            appendNote("Compacting context…")
            return true

        case "compaction_end":
            lock.lock(); isCompacting = false; lock.unlock()
            var summary = payload["summary"]?.stringValue ?? ""
            if summary.isEmpty { summary = "Context compacted." }
            lock.lock()
            var item = TranscriptItem(
                id: "compact-\(items.count)", kind: .compaction, timestamp: Date())
            item.text = summary
            items.append(item)
            lock.unlock()
            return true

        case "auto_retry_start":
            let reason = payload["error"]?.stringValue ?? payload["reason"]?.stringValue ?? "transient error"
            appendNote("Retrying after \(reason)")
            return true

        case "extension_error":
            appendNote("Extension error: "
                + (payload["error"]?.stringValue ?? payload.compactJSON))
            return true

        default:
            return false
        }
    }

    private func applyStreamingDelta(_ payload: JSONValue) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let idx = streamingItemIndex, items.indices.contains(idx) else { return false }
        guard let ev = payload["assistantMessageEvent"] else { return false }
        let kind = ev["type"]?.stringValue ?? ""

        switch kind {
        case "text_start":
            items[idx].blocks.append(.text(""))
        case "text_delta":
            let delta = ev["delta"]?.stringValue ?? ""
            appendToLastBlock(idx: idx, delta: delta, thinking: false)
        case "thinking_start":
            items[idx].blocks.append(.thinking(""))
        case "thinking_delta":
            let delta = ev["delta"]?.stringValue ?? ""
            appendToLastBlock(idx: idx, delta: delta, thinking: true)
        case "toolcall_end":
            if let call = ev["toolCall"] {
                items[idx].blocks.append(.toolCall(ToolCall(
                    id: call["id"]?.stringValue ?? UUID().uuidString,
                    name: call["name"]?.stringValue ?? "tool",
                    arguments: call["arguments"] ?? .object([:]))))
            }
        case "error":
            items[idx].errorMessage = ev["error"]?.stringValue
                ?? ev["reason"]?.stringValue ?? "error"
        default:
            return false
        }
        return true
    }

    /// Deltas land on the open block of the matching kind. Reconstructing from the
    /// event's `partial` message on every token would be correct but quadratic; a long
    /// streamed answer is thousands of deltas.
    private func appendToLastBlock(idx: Int, delta: String, thinking: Bool) {
        guard !delta.isEmpty else { return }
        if thinking {
            if case .thinking(let existing)? = items[idx].blocks.last {
                items[idx].blocks[items[idx].blocks.count - 1] = .thinking(existing + delta)
            } else {
                items[idx].blocks.append(.thinking(delta))
            }
        } else {
            if case .text(let existing)? = items[idx].blocks.last {
                items[idx].blocks[items[idx].blocks.count - 1] = .text(existing + delta)
            } else {
                items[idx].blocks.append(.text(delta))
            }
        }
    }

    private func applyMessageEnd(_ payload: JSONValue) -> Bool {
        let role = payload.path("message.role")?.stringValue ?? ""
        lock.lock(); defer { lock.unlock() }

        switch role {
        case "assistant":
            guard let idx = streamingItemIndex, items.indices.contains(idx) else { return false }
            let msg = payload["message"] ?? .null
            // Replace the accumulated blocks with the authoritative final message: the
            // engine's version is canonical and includes anything we missed.
            let final = ContentBlock.parse(msg["content"])
            if !final.isEmpty { items[idx].blocks = final }
            items[idx].model = msg["model"]?.stringValue ?? items[idx].model
            items[idx].provider = msg["provider"]?.stringValue ?? items[idx].provider
            items[idx].stopReason = msg["stopReason"]?.stringValue
            items[idx].errorMessage = msg["errorMessage"]?.stringValue
            let u = Usage(json: msg["usage"])
            items[idx].usage = u
            usage += u
            streamingItemIndex = nil
            return true

        case "toolResult":
            // Already handled by tool_execution_end; nothing to add.
            return false

        case "bashExecution":
            let msg = payload["message"] ?? .null
            var item = TranscriptItem(id: "bash-\(items.count)", kind: .bash, timestamp: Date())
            item.command = msg["command"]?.stringValue
            item.text = Ansi.strip(msg["output"]?.stringValue ?? "")
            item.exitCode = msg["exitCode"]?.intValue
            items.append(item)
            return true

        case "custom":
            let msg = payload["message"] ?? .null
            let ctype = msg["customType"]?.stringValue ?? "extension"
            guard msg["display"]?.boolValue != false else { return false }
            var item = TranscriptItem(
                id: "custom-\(items.count)",
                kind: ctype == "agent_message" ? .agentMessage : .custom,
                timestamp: Date())
            item.customType = ctype
            item.text = msg["content"]?.textContent ?? ""
            item.senderName = AgentMessageHeader.senderName(from: item.text)
            items.append(item)
            return true

        case "user":
            // Echo of a prompt we already added locally; skip to avoid a double.
            return false

        default:
            return false
        }
    }

    public func reset() {
        lock.lock()
        items.removeAll()
        usage = Usage()
        streamingItemIndex = nil
        toolIndexByCallID.removeAll()
        toolStartTimes.removeAll()
        isStreaming = false
        lock.unlock()
    }
}

// MARK: - File watching

/// Watches a session file and reports when it grows.
///
/// Polling rather than a `DispatchSource` file event: the file is appended to by another
/// process, sometimes many times per second, and coalescing on a fixed interval is both
/// cheaper and steadier for a UI than one redraw per write. The interval backs off when a
/// session goes quiet so an idle window costs nothing.
public final class SessionWatcher: @unchecked Sendable {
    private let url: URL
    private var task: Task<Void, Never>?
    private var lastSize: Int = -1
    private var lastMTime: Date = .distantPast

    public init(url: URL) { self.url = url }

    /// Calls `onChange` whenever the file's size or mtime moves.
    public func start(onChange: @escaping @Sendable () -> Void) {
        stop()
        task = Task.detached { [weak self] in
            var idleTicks = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.checkChanged() {
                    idleTicks = 0
                    onChange()
                } else {
                    idleTicks += 1
                }
                // 400ms while active, easing to 3s when nothing has happened for a while.
                let interval: UInt64 = idleTicks > 30 ? 3_000_000_000 : 400_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func checkChanged() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        defer { lastSize = size; lastMTime = mtime }
        if lastSize == -1 { return false }  // first observation is the baseline
        return size != lastSize || mtime != lastMTime
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
