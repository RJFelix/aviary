import Foundation

/// One row in the sessions list.
public struct SessionSummary: Sendable, Identifiable, Hashable {
    /// The displayed row identity. Legacy rows use their transcript filename without the
    /// extension; canonical-only rows use an authority-qualified journal identity.
    ///
    /// For legacy rows, this is **not** the `id` inside the JSONL header, which disagrees with the filename in the
    /// large majority of real sessions (68 of 80 in one checkout). Everything else in the
    /// ecosystem keys on the filename — `session-artifacts/<id>/`, the spawn ledger's
    /// `parentSessionId`, and `list --json`'s `sessionId` — so the filename is canonical and
    /// the header field is the outlier. Using the header id silently breaks live-state
    /// matching, sub-agent grouping, kernel-state lookup and recorded-payload attribution
    /// for most sessions, and each failure looks like missing data rather than a bad join.
    /// Canonical-only rows set `isCanonicalOnly` and have no legacy transcript identity or URL.
    public var id: String
    /// The `id` recorded inside the transcript header, kept for reference only.
    public var headerID: String?
    /// Legacy transcript location, absent for a native canonical row that has no compatibility
    /// file. Callers must not manufacture a path for observe-only canonical entries.
    public var fileURL: URL?
    public var name: String?
    public var cwd: String
    public var gitBranch: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var byteSize: Int
    public var provider: String?
    public var model: String?
    public var usage: Usage
    public var childUsage: Usage
    public var counts: Transcript.Counts
    public var firstPrompt: String
    public var lastAssistantText: String
    public var status: AgentStatus?
    public var sessionState: String?
    public var rlmDepth: Int
    public var parentSessionPath: String?
    public var childCount: Int = 0
    /// True when a daemon worker currently holds this session.
    public var isLive: Bool = false
    /// True when a live worker is mid-operation.
    public var isBusy: Bool = false
    public var liveOperation: String?
    /// Catalog-only visibility state. The transcript and artifacts stay in place.
    public var isArchived: Bool = false
    /// True for a native canonical row with no legacy transcript compatibility identity.
    /// Such a row can be observed, but legacy transcript/artifact operations are unavailable.
    public var isCanonicalOnly: Bool = false

    public var title: String {
        if let n = name, !n.isEmpty { return n }
        let p = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { return String(p.prefix(120)) }
        return "Untitled session"
    }

    public var projectName: String {
        cwd.isEmpty ? "—" : URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var totalUsage: Usage { usage }

    /// Session-level "shape": is this a quick question or a long agentic run?
    public var isSubstantial: Bool {
        counts.assistant >= 3 || counts.toolCalls >= 3
    }
}

/// The result of a batch Trash request. A bad file must not stop later selected sessions
/// from moving to Trash, and the UI needs exact identities to leave failed rows selected.
public struct SessionTrashResult: Sendable {
    public var trashedIDs: Set<String>
    public var failures: [String: String]
    /// The transcript moved, so its catalog row is gone, but a companion resource did not.
    /// Kept separate from `failures`, whose rows remain in the catalog and can be retried.
    public var partialFailures: [String: String]

    public init(
        trashedIDs: Set<String> = [], failures: [String: String] = [:],
        partialFailures: [String: String] = [:]
    ) {
        self.trashedIDs = trashedIDs
        self.failures = failures
        self.partialFailures = partialFailures
    }
}

/// One production catalog refresh across the legacy transcript compatibility store and the
/// native Timeline journals. Session rows are joined only by an unambiguous local Session id;
/// Work remains an independent inventory because a Work Host can outlive or serve many GUIs.
public struct SessionCatalogScanResult: Sendable {
    public let entries: [SessionCatalogProjection]
    public let workInventory: [LocalTimelineCatalog.WorkRow]
    public let diagnostics: [LocalTimelineCatalog.Diagnostic]
    /// Discovery/read completeness from the native catalog is carried separately because a
    /// bounded diagnostic list can otherwise hide an omitted journal.
    public let canonicalNotificationSourceComplete: Bool
    /// Local legacy Session ids whose native journal cannot prove attachment/liveness truth.
    /// Transcript actions must fail closed for these ids even when no canonical companion could
    /// be constructed from the corrupt or ambiguous native record.
    public let nativeActionBlockedSessionIDs: Set<String>
    /// Legacy transcript ids paired with a valid native Session. This provenance is deliberately
    /// separate from canonicalByID, whose map also contains legacy adapters.
    public let nativeCompanionLegacyIDs: Set<String>

    public init(
        entries: [SessionCatalogProjection],
        workInventory: [LocalTimelineCatalog.WorkRow],
        diagnostics: [LocalTimelineCatalog.Diagnostic],
        canonicalNotificationSourceComplete: Bool = true,
        nativeActionBlockedSessionIDs: Set<String> = [],
        nativeCompanionLegacyIDs: Set<String> = []
    ) {
        self.entries = entries
        self.workInventory = workInventory
        self.diagnostics = diagnostics
        self.canonicalNotificationSourceComplete = canonicalNotificationSourceComplete
        self.nativeActionBlockedSessionIDs = nativeActionBlockedSessionIDs
        self.nativeCompanionLegacyIDs = nativeCompanionLegacyIDs
    }
}

/// Scans and caches the session catalog.
///
/// Reimplemented natively rather than shelling out to the harness's catalog process: the
/// files are the source of truth, reading them is a few milliseconds each, and a native
/// scan keeps the sessions list responsive while a daemon is wedged — precisely when you
/// most want to look at what happened.
public actor SessionCatalog {
    /// Bump when anything about how a summary is derived changes.
    ///
    /// The cache keys on file size and mtime, which correctly detects a *changed
    /// transcript* and completely misses a changed *parser*. Without this, improving how
    /// titles are extracted silently does nothing for every session already indexed.
    static let schemaVersion = 6

    private let home: AgentHome
    private let trashItem: @Sendable (URL) throws -> Void
    private var cache: [String: CacheEntry] = [:]
    private let cacheFileURL: URL

    private struct CacheEntry: Codable {
        var mtime: Date
        var size: Int
        var summary: StoredSummary
    }

    public init(home: AgentHome) {
        self.init(home: home) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Test seam for deterministic partial-failure coverage. Production always supplies the
    /// macOS Trash operation above; tests can fail only the artifact crossing without touching
    /// the user's real Trash.
    init(home: AgentHome, trashItem: @escaping @Sendable (URL) throws -> Void) {
        self.home = home
        self.trashItem = trashItem
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appending(path: "Aviary", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheFileURL = dir.appending(path: "catalog-cache-v\(Self.schemaVersion).json")
        cache = Self.loadCache(from: cacheFileURL)
    }

    // MARK: Scan

    /// Enumerate and summarize every session, newest first.
    ///
    /// `progress` is called on a detached task as files are processed, so a first run over
    /// a large sessions directory can show a determinate bar instead of a spinner.
    public func scan(progress: (@Sendable (Int, Int) -> Void)? = nil) -> [SessionSummary] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: home.sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let jsonl = files.filter { $0.pathExtension == "jsonl" }
        var out: [SessionSummary] = []
        out.reserveCapacity(jsonl.count)

        for (i, url) in jsonl.enumerated() {
            progress?(i, jsonl.count)
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = attrs?.contentModificationDate ?? .distantPast
            let size = attrs?.fileSize ?? 0
            let key = url.lastPathComponent

            if let hit = cache[key], hit.mtime == mtime, hit.size == size {
                out.append(hit.summary.restore(fileURL: url))
                continue
            }
            guard var s = Self.summarize(fileURL: url) else { continue }
            s.updatedAt = mtime
            s.byteSize = size
            cache[key] = CacheEntry(mtime: mtime, size: size, summary: StoredSummary(s))
            out.append(s)
        }
        progress?(jsonl.count, jsonl.count)

        // Child (RLM) session counts come from the ledger, which is the only place the
        // parent→child edge is recorded.
        let tree = AgentTreeReader.read(home: home)
        var childCounts: [String: Int] = [:]
        for edge in tree.edges {
            childCounts[edge.parentSessionID, default: 0] += 1
        }
        let archived = archivedSessionIDs()
        for i in out.indices {
            out[i].childCount = childCounts[out[i].id] ?? 0
            out[i].isArchived = archived.contains(out[i].id)
        }

        saveCache()
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Read catalog entries through the canonical projection boundary.
    ///
    /// Native Timeline rows supply lifecycle/model/attention/Work truth. A same-id legacy
    /// transcript remains the compatibility identity for transcript and artifact actions, but
    /// never supplies missing native facts. Native-only sessions are observe-only, and Work is
    /// returned independently rather than hidden behind whichever Session happens to be open.
    public func scanCatalog(
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> SessionCatalogScanResult {
        let legacy = scan(progress: progress)
        let native = LocalTimelineCatalog.scan(home: home)
        let nativeByLocalSessionID = Dictionary(grouping: native.sessionSummaries) {
            $0.session.sessionID
        }
        var actionBlockedSessionIDs = Set(native.sessions.compactMap { row -> String? in
            guard row.summary == nil, let journal = row.journal,
                  case .session(let session) = journal.owner
            else { return nil }
            return session.sessionID
        })
        for (sessionID, candidates) in nativeByLocalSessionID where candidates.count > 1 {
            actionBlockedSessionIDs.insert(sessionID)
        }
        var matchedCanonicalIDs = Set<String>()
        var companionLegacyIDs = Set<String>()
        var diagnostics = native.diagnostics
        var entries: [SessionCatalogProjection] = []
        entries.reserveCapacity(legacy.count + native.sessionSummaries.count)

        for summary in legacy {
            let candidates = nativeByLocalSessionID[summary.id] ?? []
            if candidates.count == 1, let canonical = candidates.first,
               let companion = SessionCatalogProjection.companion(
                   canonical: canonical, legacySummary: summary)
            {
                entries.append(companion)
                matchedCanonicalIDs.insert(canonical.id)
                companionLegacyIDs.insert(summary.id)
            } else {
                entries.append(LegacySessionCatalogAdapter.project(
                    summary: summary, authorityID: home.workHostID))
                if candidates.count > 1 {
                    diagnostics.append(LocalTimelineCatalog.Diagnostic(
                        kind: "ambiguous_session_companion",
                        message: "Session \(summary.id) has \(candidates.count) native authorities; legacy companion was not paired"))
                }
            }
        }

        entries.append(contentsOf: native.sessionSummaries
            .filter { !matchedCanonicalIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
            .map(SessionCatalogProjection.canonical))
        return SessionCatalogScanResult(
            entries: entries, workInventory: native.works, diagnostics: diagnostics,
            canonicalNotificationSourceComplete: native.canonicalNotificationSourceComplete,
            nativeActionBlockedSessionIDs: actionBlockedSessionIDs,
            nativeCompanionLegacyIDs: companionLegacyIDs)
    }

    /// Convert the typed boundary into rows the current list can render. Native canonical rows
    /// are retained as observe-only summaries; only legacy rows have a transcript URL.
    public static func displaySummaries(
        from entries: [SessionCatalogProjection]
    ) -> [SessionSummary] {
        entries.compactMap(\.displaySummary)
    }

    /// Single-pass summary. Reads the file once and extracts only list-view fields —
    /// notably skipping the thousands of `agent_status` entries a long session accumulates.
    public static func summarize(fileURL: URL) -> SessionSummary? {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
        let fallbackID = fileURL.deletingPathExtension().lastPathComponent

        var header: SessionHeader?
        var s = SessionSummary(
            id: fallbackID, headerID: nil, fileURL: fileURL, name: nil, cwd: "", gitBranch: nil,
            createdAt: .distantPast, updatedAt: .distantPast, byteSize: data.count,
            provider: nil, model: nil, usage: Usage(), childUsage: Usage(),
            counts: Transcript.Counts(), firstPrompt: "", lastAssistantText: "",
            status: nil, sessionState: nil, rlmDepth: 0, parentSessionPath: nil)

        for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var slice = Data(chunk)
            if slice.last == UInt8(ascii: "\r") { slice.removeLast() }
            guard !slice.isEmpty, let v = JSONValue.parse(slice) else { continue }
            let type = v["type"]?.stringValue ?? ""
            s.counts.entries += 1

            switch type {
            case "session":
                let h = SessionHeader(json: v, fallbackID: fallbackID)
                header = h
                // s.id stays the filename stem — see the note on SessionSummary.id.
                s.headerID = h.id == fallbackID ? nil : h.id
                s.cwd = h.cwd
                s.createdAt = h.timestamp
                s.gitBranch = h.gitBranch
                s.rlmDepth = h.rlmDepth
                s.parentSessionPath = h.parentSession

            case "session_info":
                s.name = v["name"]?.stringValue ?? s.name

            case "session_state":
                s.sessionState = v.path("state.status")?.stringValue ?? s.sessionState

            case "agent_status":
                s.status = AgentStatus(
                    summary: v.path("status.summary")?.stringValue ?? "",
                    taskState: v.path("status.taskState")?.stringValue,
                    basedOnMessageCount: v.path("status.basedOnMessageCount")?.intValue,
                    timestamp: ISO8601.date(v["timestamp"]?.stringValue) ?? .distantPast)

            case "child_usage_attributed":
                s.childUsage += v["childUsage"].map { Usage(json: $0) }
                    ?? .unclassifiedRecord

            case "model_change":
                s.provider = v["provider"]?.stringValue ?? s.provider
                s.model = v["modelId"]?.stringValue ?? s.model

            case "git_state":
                s.gitBranch = v.path("git.branch")?.stringValue ?? s.gitBranch

            case "message", "custom_message":
                let msg = type == "custom_message" ? v : (v["message"] ?? .null)
                let role = type == "custom_message" ? "custom" : (msg["role"]?.stringValue ?? "")
                switch role {
                case "user":
                    s.counts.user += 1
                    if s.firstPrompt.isEmpty {
                        // Strip hook-injected context blocks first, or every session in the
                        // list ends up titled with the same multi-kilobyte preamble.
                        s.firstPrompt = Self.condense(
                            PromptText.userFacing(msg["content"]?.textContent ?? ""))
                    }
                case "assistant":
                    s.counts.assistant += 1
                    s.usage += msg["usage"].map { Usage(json: $0) }
                        ?? .unclassifiedRecord
                    s.model = msg["model"]?.stringValue ?? s.model
                    s.provider = msg["provider"]?.stringValue ?? s.provider
                    let blocks = msg["content"]?.arrayValue ?? []
                    for b in blocks {
                        if b["type"]?.stringValue == "toolCall" { s.counts.toolCalls += 1 }
                        if b["type"]?.stringValue == "text", let t = b["text"]?.stringValue,
                           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            s.lastAssistantText = Self.condense(t)
                        }
                    }
                case "toolResult":
                    if msg["isError"]?.boolValue == true { s.counts.toolErrors += 1 }
                case "bashExecution":
                    s.counts.bash += 1
                case "compactionSummary":
                    s.counts.compactions += 1
                case "custom":
                    let ctype = (type == "custom_message"
                        ? v["customType"]?.stringValue
                        : msg["customType"]?.stringValue) ?? ""
                    if ctype == "agent_message" { s.counts.agentMessages += 1 }
                    if ctype == "aviary.usage-snapshot.v1",
                       let usage = Usage.recordedSnapshot(v) { s.usage = usage }
                default:
                    break
                }

            case "compaction":
                s.counts.compactions += 1

            default:
                break
            }
        }

        guard header != nil else { return nil }
        if s.createdAt == .distantPast { s.createdAt = s.updatedAt }
        return s
    }

    /// Collapse whitespace and clip, for list rows.
    static func condense(_ s: String, limit: Int = 300) -> String {
        let flat = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: Delete

    /// Move a session (and its artifacts) to the Trash. Never an unlink: transcripts are
    /// the only record of work an agent did. The native Session owner lock spans the fresh
    /// liveness read and transcript move, so a cooperating Work Host cannot enter between them.
    public func trash(session: SessionSummary) throws -> String? {
        guard let fileURL = session.fileURL else {
            throw NSError(domain: "AviarySessionCatalog", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "This canonical session has no legacy transcript to move."])
        }
        let nativeSession = SessionRef(session.id)
        let nativeJournal = JournalRef.session(
            nativeSession, authority: TimelineAuthorityRef(home.workHostID))
        return try TimelineJournalWriter.withAdvisoryOwnerLock(
            home: home, journal: nativeJournal,
            dataURL: home.timelineV2SessionJournalURL(nativeSession)
        ) {
            guard !LocalTimelineCatalog.blocksLegacyAction(
                home: home, sessionID: session.id)
            else {
                throw NSError(
                    domain: "AviarySessionCatalog", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Native Work is active or its state cannot be proven; the transcript was not moved."])
            }
            return try trashUnlocked(session: session, fileURL: fileURL)
        }
    }

    private func trashUnlocked(session: SessionSummary, fileURL: URL) throws -> String? {
        try trashItem(fileURL)
        var partialFailures: [String] = []
        let artifacts = home.artifacts(forSession: session.id)
        if FileManager.default.fileExists(atPath: artifacts.path) {
            do {
                try trashItem(artifacts)
            } catch {
                partialFailures.append(
                    "Transcript moved, but artifacts remain at \(artifacts.path): "
                        + error.localizedDescription)
            }
        }
        cache.removeValue(forKey: fileURL.lastPathComponent)
        var archived = archivedSessionIDs()
        if archived.remove(session.id) != nil {
            do {
                try writeArchivedSessionIDs(archived)
            } catch {
                partialFailures.append(
                    "Archive metadata could not be updated: \(error.localizedDescription)")
            }
        }
        saveCache()
        return partialFailures.isEmpty ? nil : partialFailures.joined(separator: "\n")
    }

    /// Hide or restore a session in the ordinary catalog without touching its durable history.
    ///
    /// The sidecar contains identities only. It is intentionally separate from the append-only
    /// transcript, because organizing a list is not part of what the agent did.
    public func setArchived(_ archived: Bool, sessionIDs: Set<String>) throws {
        var ids = archivedSessionIDs()
        if archived {
            ids.formUnion(sessionIDs)
        } else {
            ids.subtract(sessionIDs)
        }
        try writeArchivedSessionIDs(ids)
    }

    /// Move every selected transcript independently. One unreadable or already-moved file
    /// reports its own failure but never prevents the rest of a deliberate batch from moving.
    public func trash(sessions: [SessionSummary]) -> SessionTrashResult {
        var result = SessionTrashResult()
        for session in sessions {
            do {
                let partialFailure = try trash(session: session)
                result.trashedIDs.insert(session.id)
                if let partialFailure { result.partialFailures[session.id] = partialFailure }
            } catch {
                result.failures[session.id] = error.localizedDescription
            }
        }
        return result
    }

    public func invalidate(_ id: String) {
        cache.removeValue(forKey: "\(id).jsonl")
    }

    public func clearCache() {
        cache.removeAll()
        try? FileManager.default.removeItem(at: cacheFileURL)
    }

    private func archivedSessionIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: home.archivedSessionsFile),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(values)
    }

    private func writeArchivedSessionIDs(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ids.sorted())
        try data.write(to: home.archivedSessionsFile, options: .atomic)
    }

    // MARK: Cache persistence

    private static func loadCache(from url: URL) -> [String: CacheEntry] {
        guard let d = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: d)
        else { return [:] }
        return decoded
    }

    private func saveCache() {
        guard let d = try? JSONEncoder().encode(cache) else { return }
        try? d.write(to: cacheFileURL, options: .atomic)
    }
}

/// Codable mirror of `SessionSummary` (which carries a URL we'd rather rebuild).
struct StoredSummary: Codable {
    var id: String
    var headerID: String?
    var name: String?
    var cwd: String
    var gitBranch: String?
    var createdAt: Date
    var updatedAt: Date
    var byteSize: Int
    var provider: String?
    var model: String?
    var usage: Usage
    var childUsage: Usage
    var firstPrompt: String
    var lastAssistantText: String
    var sessionState: String?
    var rlmDepth: Int
    var parentSessionPath: String?
    var statusSummary: String?
    var statusTaskState: String?
    var statusMessageCount: Int?
    var statusTimestamp: Date?
    var cUser: Int
    var cAssistant: Int
    var cToolCalls: Int
    var cToolErrors: Int
    var cBash: Int
    var cCompactions: Int
    var cAgentMessages: Int
    var cEntries: Int

    init(_ s: SessionSummary) {
        id = s.id; headerID = s.headerID; name = s.name; cwd = s.cwd; gitBranch = s.gitBranch
        createdAt = s.createdAt; updatedAt = s.updatedAt; byteSize = s.byteSize
        provider = s.provider; model = s.model; usage = s.usage; childUsage = s.childUsage
        firstPrompt = s.firstPrompt; lastAssistantText = s.lastAssistantText
        sessionState = s.sessionState; rlmDepth = s.rlmDepth
        parentSessionPath = s.parentSessionPath
        statusSummary = s.status?.summary
        statusTaskState = s.status?.taskState
        statusMessageCount = s.status?.basedOnMessageCount
        statusTimestamp = s.status?.timestamp
        cUser = s.counts.user; cAssistant = s.counts.assistant
        cToolCalls = s.counts.toolCalls; cToolErrors = s.counts.toolErrors
        cBash = s.counts.bash; cCompactions = s.counts.compactions
        cAgentMessages = s.counts.agentMessages; cEntries = s.counts.entries
    }

    func restore(fileURL: URL?) -> SessionSummary {
        var counts = Transcript.Counts()
        counts.user = cUser; counts.assistant = cAssistant
        counts.toolCalls = cToolCalls; counts.toolErrors = cToolErrors
        counts.bash = cBash; counts.compactions = cCompactions
        counts.agentMessages = cAgentMessages; counts.entries = cEntries
        var status: AgentStatus?
        if let ss = statusSummary {
            status = AgentStatus(
                summary: ss, taskState: statusTaskState,
                basedOnMessageCount: statusMessageCount,
                timestamp: statusTimestamp ?? .distantPast)
        }
        return SessionSummary(
            id: id, headerID: headerID, fileURL: fileURL, name: name, cwd: cwd, gitBranch: gitBranch,
            createdAt: createdAt, updatedAt: updatedAt, byteSize: byteSize,
            provider: provider, model: model, usage: usage, childUsage: childUsage,
            counts: counts, firstPrompt: firstPrompt, lastAssistantText: lastAssistantText,
            status: status, sessionState: sessionState, rlmDepth: rlmDepth,
            parentSessionPath: parentSessionPath)
    }
}
