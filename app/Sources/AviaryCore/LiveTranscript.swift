import Foundation

// MARK: - Live transcript identity and reconciliation

/// The stable identity of a logical turn.  This is allocated by the run controller before
/// an engine starts and is deliberately independent of a provider's stream or process ID.
/// A provider may be restarted, or a GUI may be reloaded, without changing this identity.
public struct LiveTranscriptTurnID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public var description: String { rawValue }
}

/// The stable identity of one renderable message within a turn.  It should be the same value
/// the writer eventually uses for the durable transcript entry's `id` when the engine can
/// choose that ID.  The overlay also matches by the durable item ID, so legacy writers remain
/// usable while they are being migrated.
public struct LiveTranscriptMessageID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public var description: String { rawValue }
}

/// A typed key for a live row.  Keeping turn and message IDs separate prevents a retry or a
/// follow-up from accidentally replacing a row from another turn merely because a provider
/// reused a message ID.
public struct LiveTranscriptIdentity: Hashable, Codable, Sendable {
    public let turnID: LiveTranscriptTurnID
    public let messageID: LiveTranscriptMessageID

    public init(turnID: LiveTranscriptTurnID, messageID: LiveTranscriptMessageID) {
        self.turnID = turnID
        self.messageID = messageID
    }

    public init(turnID: String, messageID: String) {
        self.init(turnID: LiveTranscriptTurnID(turnID), messageID: LiveTranscriptMessageID(messageID))
    }
}

/// The lifecycle of an ephemeral row.  Terminal states remain visible until the next
/// committed snapshot proves that the durable row is present; this closes the small window
/// between a provider callback and the writer/file watcher without inventing another row.
public enum LiveTranscriptLifecycle: String, Codable, Hashable, Sendable {
    case pending
    case streaming
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .pending, .streaming: return false
        }
    }
}

/// A bounded content update for a streaming message. Adapters can either send a complete
/// `TranscriptItem` in a delta or append one of these typed pieces to the previous item. The
/// latter keeps text and thinking accumulation in core, so each driver cannot accidentally
/// implement a subtly different concatenation rule.
public enum LiveTranscriptContentDelta: Sendable, Equatable, Hashable {
    case text(String)
    case thinking(String)
}

/// One ephemeral update to a live transcript row.
///
/// `item` may be nil for a lifecycle-only update (for example, a turn that was cancelled
/// before its first provider token).  A nil update retains an earlier item for the same
/// identity, if one exists.  `revision` is optional ordering evidence from the adapter: zero
/// means "no ordering claim", while positive revisions reject an older update for the same
/// identity.  Reapplying the same delta is always safe.
public struct LiveTranscriptDelta: Sendable, Equatable, Identifiable {
    public let identity: LiveTranscriptIdentity
    public var item: TranscriptItem?
    public var content: LiveTranscriptContentDelta?
    public var lifecycle: LiveTranscriptLifecycle
    public var revision: UInt64

    public var id: LiveTranscriptIdentity { identity }

    public init(
        identity: LiveTranscriptIdentity,
        item: TranscriptItem? = nil,
        content: LiveTranscriptContentDelta? = nil,
        lifecycle: LiveTranscriptLifecycle,
        revision: UInt64 = 0
    ) {
        self.identity = identity
        self.item = item
        self.content = content
        self.lifecycle = lifecycle
        self.revision = revision
    }

    public init(
        turnID: String,
        messageID: String,
        item: TranscriptItem? = nil,
        content: LiveTranscriptContentDelta? = nil,
        lifecycle: LiveTranscriptLifecycle,
        revision: UInt64 = 0
    ) {
        self.init(
            identity: LiveTranscriptIdentity(turnID: turnID, messageID: messageID),
            item: item,
            content: content,
            lifecycle: lifecycle,
            revision: revision)
    }
}

/// The result of projecting durable transcript rows plus the current ephemeral overlay.
/// `items` is the only collection a renderer should consume.  `live` is exposed separately so
/// controls can show a truthful lifecycle without deriving it from the rendered text.
public struct LiveTranscriptSnapshot: Sendable, Equatable {
    public let committed: [TranscriptItem]
    public let live: [LiveTranscriptDelta]

    public init(committed: [TranscriptItem], live: [LiveTranscriptDelta]) {
        self.committed = committed
        self.live = live
    }

    /// A committed item wins when it has the same durable ID as an ephemeral item.  This is
    /// the final duplicate guard even when an adapter accidentally uses two identity keys for
    /// the same provider message.
    public var items: [TranscriptItem] {
        var result = committed
        var seen = Set(committed.map(\.id))
        for delta in live {
            guard let item = delta.item, !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            result.append(item)
        }
        return result
    }

    public var isStreaming: Bool {
        live.contains { $0.lifecycle == .streaming || $0.lifecycle == .pending }
    }

    public func lifecycle(for identity: LiveTranscriptIdentity) -> LiveTranscriptLifecycle? {
        live.first(where: { $0.identity == identity })?.lifecycle
    }
}

/// Merges a durable transcript snapshot with provider deltas until the durable writer catches
/// up.  It is intentionally ephemeral: callers must recreate it from the committed snapshot
/// after a GUI reload, then feed any still-live deltas from the run controller.
///
/// The class is lock-backed because provider callbacks, file watchers, and the main-actor UI
/// can arrive concurrently.  `apply` and `reconcile` are idempotent and return a complete
/// immutable projection, making it safe for a renderer to publish the result directly.
public final class LiveTranscriptOverlay: @unchecked Sendable {
    private struct Entry: Sendable {
        var delta: LiveTranscriptDelta
        var order: UInt64
        /// The adapter event that produced `delta`. `delta` may contain a materialized item
        /// after content accumulation, so comparing it directly cannot recognize a replay of
        /// an unnumbered callback whose original item was nil.
        var lastInput: LiveTranscriptDelta
    }

    private let lock = NSLock()
    private var committed: [TranscriptItem]
    private var entries: [LiveTranscriptIdentity: Entry] = [:]
    private var nextOrder: UInt64 = 0

    public init(committed: [TranscriptItem] = []) {
        self.committed = committed
    }

    /// The current immutable projection.
    public var snapshot: LiveTranscriptSnapshot {
        lock.lock(); defer { lock.unlock() }
        return makeSnapshot()
    }

    /// Applies or replaces one live row.  Repeated callbacks with the same identity do not
    /// append another row.  Positive revisions are monotonic per identity; a stale callback
    /// is ignored rather than rolling the visible stream backwards.
    @discardableResult
    public func apply(_ delta: LiveTranscriptDelta) -> LiveTranscriptSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let prior = entries[delta.identity] {
            if delta.revision == 0 && prior.lastInput == delta {
                // Provider retries can replay an unnumbered callback. Do not append the same
                // text/thinking piece twice just because it crossed the adapter boundary again.
                return makeSnapshot()
            }
            // A positive revision is an ordering claim, so equal and older revisions cannot
            // overwrite the value already accepted. Revision zero intentionally makes no
            // ordering claim and is accepted as-is.
            if delta.revision > 0 && prior.delta.revision >= delta.revision {
                return makeSnapshot()
            }
            // A terminal outcome is final for this identity. A late provider callback must
            // not make a failed/cancelled turn look live again; start a new turn instead.
            if prior.delta.lifecycle.isTerminal && !delta.lifecycle.isTerminal {
                return makeSnapshot()
            }
            if prior.delta.lifecycle.isTerminal && delta.lifecycle.isTerminal && delta.revision == 0 {
                // Without ordering evidence, retain the first terminal outcome observed for an
                // identity. Competing terminal outcomes need a new revision or a new turn ID.
                return makeSnapshot()
            }
        }

        var replacement = delta
        if replacement.item == nil {
            replacement.item = entries[delta.identity]?.delta.item
        }
        if let content = replacement.content {
            var item = replacement.item ?? TranscriptItem(
                id: delta.identity.messageID.rawValue,
                kind: .assistant,
                timestamp: Date())
            Self.append(content, to: &item)
            replacement.item = item
        }
        if entries[delta.identity] == nil {
            entries[delta.identity] = Entry(
                delta: replacement, order: nextOrder, lastInput: delta)
            nextOrder &+= 1
        } else {
            let order = entries[delta.identity]?.order ?? nextOrder
            entries[delta.identity] = Entry(
                delta: replacement, order: order, lastInput: delta)
        }
        return makeSnapshot()
    }

    /// Convenience for adapters that have not yet constructed the typed identity.
    @discardableResult
    public func apply(
        turnID: String,
        messageID: String,
        item: TranscriptItem? = nil,
        content: LiveTranscriptContentDelta? = nil,
        lifecycle: LiveTranscriptLifecycle,
        revision: UInt64 = 0
    ) -> LiveTranscriptSnapshot {
        apply(LiveTranscriptDelta(
            turnID: turnID,
            messageID: messageID,
            item: item,
            content: content,
            lifecycle: lifecycle,
            revision: revision))
    }

    /// Replaces the durable side with a fresh parser/reducer snapshot and removes every live
    /// entry proven to be committed.  Matching uses both the transcript item's ID and the
    /// stable message ID, which lets a migrated adapter use a provider-independent key while
    /// legacy writers continue emitting their existing event IDs.
    @discardableResult
    public func reconcile(committed newCommitted: [TranscriptItem]) -> LiveTranscriptSnapshot {
        lock.lock(); defer { lock.unlock() }
        committed = newCommitted
        let committedIDs = Set(committed.map(\.id))
        entries = entries.filter { identity, entry in
            !committedIDs.contains(entry.delta.item?.id ?? "")
                && !committedIDs.contains(identity.messageID.rawValue)
        }
        return makeSnapshot()
    }

    /// Records a writer-confirmed durable item and removes exactly the corresponding live
    /// identity. This explicit mapping is important for legacy writers whose generated event
    /// ID differs from the provider message ID; callers do not need to infer identity from text
    /// or wait for a file watcher to catch up.
    @discardableResult
    public func commit(
        identity: LiveTranscriptIdentity,
        committedItem: TranscriptItem
    ) -> LiveTranscriptSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let index = committed.firstIndex(where: { $0.id == committedItem.id }) {
            committed[index] = committedItem
        } else {
            committed.append(committedItem)
        }
        entries.removeValue(forKey: identity)
        return makeSnapshot()
    }

    /// Removes one ephemeral identity when the controller has durably recorded its terminal
    /// outcome outside the transcript (for example, a cancelled pre-token turn). This is an
    /// explicit operation; terminal overlays are otherwise retained until `commit` or reload.
    @discardableResult
    public func remove(identity: LiveTranscriptIdentity) -> LiveTranscriptSnapshot {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: identity)
        return makeSnapshot()
    }

    /// Drops the overlay while retaining no stale provider state.  Useful when a run ends and
    /// its next durable reload is authoritative.
    @discardableResult
    public func clear() -> LiveTranscriptSnapshot {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        return makeSnapshot()
    }

    private func makeSnapshot() -> LiveTranscriptSnapshot {
        let live = entries.values
            .sorted { $0.order < $1.order }
            .map(\.delta)
        return LiveTranscriptSnapshot(committed: committed, live: live)
    }

    private static func append(_ content: LiveTranscriptContentDelta, to item: inout TranscriptItem) {
        switch content {
        case .text(let value):
            guard !value.isEmpty else { return }
            if let last = item.blocks.last, case .text(let prior) = last {
                item.blocks[item.blocks.count - 1] = .text(prior + value)
            } else {
                item.blocks.append(.text(value))
            }
        case .thinking(let value):
            guard !value.isEmpty else { return }
            if let last = item.blocks.last, case .thinking(let prior) = last {
                item.blocks[item.blocks.count - 1] = .thinking(prior + value)
            } else {
                item.blocks.append(.thinking(value))
            }
        }
    }
}

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

    // The harness fed this builder over JSON-RPC — `apply(_ RPCMessage)` and the event,
    // streaming-delta and message-end handling under it. All of it went with the fork.
    // What survives is what every engine still needs: a place to put a local user message
    // and a note, and the change-tracking that drives a redraw.


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
