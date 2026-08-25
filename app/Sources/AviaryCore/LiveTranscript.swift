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
