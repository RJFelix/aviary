import Foundation

/// What the agent has learned, and how much of it a request carries.
///
/// This is Aviary's answer to the harness's continual harness, and it exists because that
/// design was measured and found wanting in four specific ways. Each one is a decision here:
///
/// 1. **The harness injected 6 entries per kind, truncated to 180 characters, sorted
///    alphabetically by path.** On a real store of 10 entries that meant 10,215 characters on
///    disk and at most 1,080 reaching the model — 89% invisible — and because the sort was
///    alphabetical the *most recently written* entry was the hidden one. Here the budget is in
///    characters, ranking is relevance then recency, and **what does not fit is still listed**.
/// 2. **It had no lifetimes.** Local entries died with the session, global ones lived forever,
///    and there was nothing in between — no project scope, no expiry, no promotion. Entries
///    here carry a scope and an optional TTL.
/// 3. **It was unreviewable**: a mode-0600 JSON blob rewritten in place. This is append-only
///    JSONL in the repository, so `git diff` shows what the agent decided to believe.
/// 4. **It recorded no provenance.** Every entry here names the session and prompt that
///    produced it, so "why does it think that?" is answerable.
public enum MemoryScope: String, Codable, Sendable, CaseIterable {
    /// Working state for one session. Dies with it, and is meant to.
    case session
    /// About this project. The tier the harness had no room for, and where most durable
    /// findings actually belong.
    case project
    /// True everywhere. Rare on purpose — a fact that is not about a project usually is not a
    /// fact about anything.
    case global

    public var label: String {
        switch self {
        case .session: return "Session"
        case .project: return "Project"
        case .global: return "Everywhere"
        }
    }
}

public struct MemoryEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var scope: MemoryScope
    public var text: String
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    /// When this stops being injected. Nil means no expiry — which should be the exception.
    public var expiresAt: Date?
    /// The session that learned it, and what was being asked at the time.
    public var sessionID: String?
    public var provenance: String?
    public var retired = false

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    public var isLive: Bool { !retired && !isExpired }
}

/// Append-only storage, one file per scope.
///
/// Event-sourced for the same reason the workshop board is: two writers — the agent and a
/// person editing a file — one log, and an append can never clobber the other's work. A wrong
/// belief is corrected forward with a `retire` event, so the mistake stays visible instead of
/// being quietly edited out of history.
public struct MemoryStore: Sendable {
    public let repoRoot: URL?
    public let home: AgentHome
    public let projectKey: String

    public init(repoRoot: URL?, home: AgentHome, cwd: String) {
        self.repoRoot = repoRoot
        self.home = home
        // Keyed by directory name rather than full path so a checkout that moves keeps its
        // memories, and two checkouts of the same project share them.
        self.projectKey = URL(fileURLWithPath: cwd).lastPathComponent
    }

    public func url(for scope: MemoryScope, sessionID: String? = nil) -> URL? {
        switch scope {
        case .global:
            return home.root.appending(path: "memory/global.jsonl")
        case .project:
            // In the repository when there is one, so `git diff` is the review surface.
            if let repoRoot { return repoRoot.appending(path: "memory/project.jsonl") }
            return home.root.appending(path: "memory/project-\(projectKey).jsonl")
        case .session:
            guard let sessionID else { return nil }
            return home.artifacts(forSession: sessionID).appending(path: "memory.jsonl")
        }
    }

    public func append(_ entry: MemoryEntry, sessionID: String?) throws {
        guard let url = url(for: entry.scope, sessionID: sessionID ?? entry.sessionID) else {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var obj: [String: JSONValue] = [
            "v": .number(1),
            "event": .string(entry.retired ? "retire" : "remember"),
            "id": .string(entry.id),
            "scope": .string(entry.scope.rawValue),
            "text": .string(entry.text),
            "tags": .array(entry.tags.map { .string($0) }),
            "at": .string(SessionWriter.stamp(entry.updatedAt)),
        ]
        if let expiresAt = entry.expiresAt {
            obj["expiresAt"] = .string(SessionWriter.stamp(expiresAt))
        }
        if let sid = entry.sessionID { obj["sessionId"] = .string(sid) }
        if let provenance = entry.provenance { obj["provenance"] = .string(provenance) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = try encoder.encode(JSONValue.object(obj))
        data.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Everything live, newest first, across every scope this session can see.
    public func load(sessionID: String?) -> [MemoryEntry] {
        var byID: [String: MemoryEntry] = [:]
        var order: [String] = []
        for scope in MemoryScope.allCases {
            guard let url = url(for: scope, sessionID: sessionID),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let entry = Self.decode(String(line), scope: scope) else { continue }
                if byID[entry.id] == nil { order.append(entry.id) }
                // A later event supersedes an earlier one for the same id — that is how a
                // retraction works without editing the file.
                if let existing = byID[entry.id], existing.updatedAt > entry.updatedAt { continue }
                byID[entry.id] = entry
            }
        }
        return order.compactMap { byID[$0] }
            .filter(\.isLive)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func decode(_ line: String, scope: MemoryScope) -> MemoryEntry? {
        guard let v = JSONValue.parse(Data(line.utf8)),
              let id = v["id"]?.stringValue
        else { return nil }
        let at = WorkshopLog.parseDate(v["at"]?.stringValue) ?? Date(timeIntervalSince1970: 0)
        return MemoryEntry(
            id: id,
            scope: MemoryScope(rawValue: v["scope"]?.stringValue ?? "") ?? scope,
            text: v["text"]?.stringValue ?? "",
            tags: (v["tags"]?.arrayValue ?? []).compactMap { $0.stringValue },
            createdAt: at,
            updatedAt: at,
            expiresAt: WorkshopLog.parseDate(v["expiresAt"]?.stringValue),
            sessionID: v["sessionId"]?.stringValue,
            provenance: v["provenance"]?.stringValue,
            retired: v["event"]?.stringValue == "retire")
    }

    public static func newID() -> String {
        "mem-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
    }
}

/// Chooses which memories a request carries, and renders them.
///
/// Same shape as `SkillGate`, and for the same reason: a budget with a visible remainder beats
/// a silent cap. The difference from the harness is the whole point — nothing is dropped
/// without being listed, and nothing is ranked by a field the content does not control.
public struct MemoryGate: Sendable {
    public var budget: Int
    /// How many to list by tag when they miss the budget. Unlike the harness's `+N more`,
    /// which told the model a number and nothing it could act on.
    public var listLimit: Int

    public init(budget: Int = 4_000, listLimit: Int = 40) {
        self.budget = budget
        self.listLimit = listLimit
    }

    public struct Selection: Sendable {
        public var included: [MemoryEntry]
        public var listed: [MemoryEntry]
        public var charactersUsed: Int
        public var totalAvailable: Int
    }

    public func select(_ entries: [MemoryEntry], prompt: String) -> Selection {
        let terms = SkillGate.terms(in: prompt)
        let scored = entries.map { entry -> (entry: MemoryEntry, score: Double) in
            let haystack = SkillGate.terms(in: entry.text + " " + entry.tags.joined(separator: " "))
            var score = Double(terms.intersection(haystack).count)
            // Session-scoped memories are working state for the task in hand, so they get a
            // thumb on the scale: they are almost always relevant and always short-lived.
            if entry.scope == .session { score += 1.5 }
            return (entry, score)
        }
        let ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.entry.updatedAt > $1.entry.updatedAt
        }
        var included: [MemoryEntry] = []
        var listed: [MemoryEntry] = []
        var used = 0
        for item in ranked {
            let cost = item.entry.text.count + 24
            if used + cost <= budget {
                included.append(item.entry)
                used += cost
            } else {
                listed.append(item.entry)
            }
        }
        return Selection(
            included: included, listed: listed, charactersUsed: used,
            totalAvailable: entries.reduce(0) { $0 + $1.text.count + 24 })
    }

    public func render(_ selection: Selection) -> String {
        guard !selection.included.isEmpty || !selection.listed.isEmpty else { return "" }
        var out = ["## What you have learned before", ""]
        for entry in selection.included {
            var line = "- \(entry.text)"
            var notes: [String] = [entry.scope.label.lowercased()]
            if let expires = entry.expiresAt {
                notes.append("expires \(Fmt.timestamp(expires))")
            }
            line += "  _(\(notes.joined(separator: ", ")))_"
            out.append(line)
        }
        if !selection.listed.isEmpty {
            out.append("")
            out.append("\(selection.listed.count) more you are not being shown in full. Call "
                + "`recall(query)` to search them:")
            // Their subjects, not just a count — a number tells the model nothing it can act
            // on, which is what `+N more <kind> entries` got wrong.
            let subjects = selection.listed.prefix(listLimit).map { entry in
                entry.tags.isEmpty ? String(entry.text.prefix(60)) : entry.tags.joined(separator: "/")
            }
            out.append("  " + subjects.joined(separator: " · "))
        }
        out.append("")
        out.append("Record something durable with `remember(text, scope='project', days=N)`. "
            + "Prefer project scope; use `days` unless it will be true indefinitely.")
        return out.joined(separator: "\n")
    }
}
