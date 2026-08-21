import Foundation

/// The improvement board: requests you make of Aviary, and the record of what happened to them.
///
/// Three decisions worth stating, because they are the whole design.
///
/// **The log is append-only JSONL, and it lives in the repository.** Not Application Support.
/// The contents are development requests against this checkout, so `git diff` is the right
/// review surface and a commit can cite the request it answers. It also means the agent
/// that services the board finds it exactly where it would look for anything else about
/// the project. Storage under `Application Support` would have hidden the one artifact
/// whose whole value is being reviewable.
///
/// **Both Aviary and the agent write to it, so it is event-sourced.** A request's current
/// state is a fold over its events rather than a record anybody rewrites. That is what
/// makes a GUI and a long-running agent safe to point at one file: an append never loses
/// the other writer's work, and a line neither of them understands is skipped rather than
/// fatal. Rewriting a mutable JSON document from two processes would have needed a lock
/// nobody would remember to take.
///
/// **A request carries a context snapshot.** "The Sessions tab looks wrong" is not
/// actionable; "the Sessions tab, with this session selected, this many transcript items,
/// the inspector open, at this window size, and here is a picture" is. Collecting that at
/// submit time costs nothing and is unrecoverable afterwards.
public enum Workshop {

    /// `<repo>/workshop` — the board, the screenshots, and the agent's standing brief.
    public static func directory(repoRoot: URL) -> URL {
        repoRoot.appending(path: "workshop", directoryHint: .isDirectory)
    }

    public static func logURL(repoRoot: URL) -> URL {
        directory(repoRoot: repoRoot).appending(path: "requests.jsonl")
    }

    public static func shotsDirectory(repoRoot: URL) -> URL {
        directory(repoRoot: repoRoot).appending(path: "shots", directoryHint: .isDirectory)
    }

    /// The agent's standing instructions. Tracked, editable, and deliberately *not* compiled
    /// into Aviary: the protocol between you and the agent servicing the board should be
    /// something you can revise without a rebuild.
    public static func briefURL(repoRoot: URL) -> URL {
        directory(repoRoot: repoRoot).appending(path: "AGENT.md")
    }

    /// Turn a known engine failure into an instruction.
    ///
    /// Only one entry so far, and it earns its place: two harness builds cannot share a
    /// daemon socket, and when the running one has busy sessions the newcomer is refused and
    /// exits. Nothing in that message tells you what to do about it, and the fix is a recipe
    /// this repo already ships. Returns nil for anything unrecognised rather than guessing —
    /// false advice about a failure is worse than none.
    public static func remedy(for output: String) -> String? {
        let lower = output.lowercased()
        let daemonConflict = lower.contains("refusing to replace stale daemon")
            || lower.contains("different prime agent version")
            || (lower.contains("stale") && lower.contains("daemon"))
        guard daemonConflict else { return nil }
        return "Aviary's engine build and the running daemon are different builds, and the "
            + "daemon has busy sessions so it will not step aside. Finish or stop those "
            + "sessions, or run `just daemon-reset` in the Aviary checkout, then send it "
            + "again from the card."
    }

    /// Sortable, short, and readable aloud — it goes in commit messages.
    public static func newID(date: Date = Date(), random: () -> UInt32 = { arc4random() }) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = .current
        return "wr-\(f.string(from: date))-\(String(format: "%04x", random() & 0xFFFF))"
    }
}

// MARK: - Vocabulary

public enum WorkshopKind: String, Codable, CaseIterable, Sendable, Hashable {
    case change, bug, idea, question

    public var label: String {
        switch self {
        case .change: return "Change"
        case .bug: return "Bug"
        case .idea: return "Idea"
        case .question: return "Question"
        }
    }

    public var symbol: String {
        switch self {
        case .change: return "slider.horizontal.3"
        case .bug: return "ant"
        case .idea: return "lightbulb"
        case .question: return "questionmark.circle"
        }
    }
}

public enum WorkshopStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case open, claimed, building, done, declined, parked

    public var label: String {
        switch self {
        case .open: return "Open"
        case .claimed: return "Claimed"
        case .building: return "Building"
        case .done: return "Done"
        case .declined: return "Declined"
        case .parked: return "Parked"
        }
    }

    /// Which board column it belongs to. Four columns, six statuses — `claimed` and
    /// `building` are one thing to a reader and two things to the agent.
    public var column: WorkshopColumn {
        switch self {
        case .open: return .inbox
        case .claimed, .building: return .working
        case .done: return .done
        case .declined, .parked: return .shelved
        }
    }

    public var isTerminal: Bool { self == .done || self == .declined }
}

public enum WorkshopColumn: String, CaseIterable, Identifiable, Sendable {
    case inbox, working, done, shelved

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .working: return "In progress"
        case .done: return "Done"
        case .shelved: return "Shelved"
        }
    }
}

// MARK: - Context snapshot

/// What Aviary looked like when you filed the request.
///
/// `facts` is a flat ordered list of grouped label/value pairs rather than a typed struct
/// per screen. That is deliberate: every new datum worth collecting would otherwise be a
/// schema change, a migration, and a decoding branch, and the consumer is a language model
/// reading prose. An ordered list renders directly as a table in the UI and as Markdown in
/// the prompt.
public struct WorkshopContext: Codable, Sendable, Hashable {
    public struct Fact: Codable, Sendable, Hashable, Identifiable {
        public var group: String
        public var label: String
        public var value: String
        public var id: String { "\(group)/\(label)" }

        public init(group: String, label: String, value: String) {
            self.group = group
            self.label = label
            self.value = value
        }
    }

    public var capturedAt: Date
    public var section: String
    public var sectionSubtitle: String
    public var facts: [Fact]
    /// Relative to the workshop directory, so the log stays portable if the checkout moves.
    public var screenshot: String?

    public init(
        capturedAt: Date = Date(),
        section: String = "",
        sectionSubtitle: String = "",
        facts: [Fact] = [],
        screenshot: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.section = section
        self.sectionSubtitle = sectionSubtitle
        self.facts = facts
        self.screenshot = screenshot
    }

    public var groups: [String] {
        var seen = Set<String>()
        return facts.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    public func facts(in group: String) -> [Fact] {
        facts.filter { $0.group == group }
    }

    /// The snapshot as Markdown, for the message sent to the agent.
    public var markdown: String {
        var out: [String] = []
        for group in groups {
            out.append("**\(group)**")
            for f in facts(in: group) {
                out.append("- \(f.label): \(f.value)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Folded state

public struct WorkshopNote: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var at: Date
    public var by: String
    public var text: String
}

public struct WorkshopRequest: Identifiable, Sendable, Hashable {
    public var id: String
    public var createdAt: Date
    public var title: String
    public var body: String
    public var kind: WorkshopKind
    public var status: WorkshopStatus
    public var statusChangedAt: Date
    public var context: WorkshopContext?
    public var notes: [WorkshopNote] = []
    /// Commits the agent says answered this.
    public var commits: [String] = []
    /// Sessions that worked on it.
    public var sessions: [String] = []
    /// True once Aviary has actually handed it to a session.
    public var delivered = false

    public var oneLine: String {
        title.isEmpty ? String(body.prefix(70)) : title
    }

    /// The message Aviary sends to the workshop session.
    ///
    /// Deliberately verbose about identity: the agent has to be able to append status
    /// events for exactly this request, and guessing an id from prose is how a board
    /// silently stops tracking anything.
    public func promptEnvelope(logPath: String, briefPath: String) -> String {
        var out: [String] = []
        out.append("## Aviary improvement request `\(id)`")
        out.append("")
        out.append("**\(kind.label):** \(title.isEmpty ? "(untitled)" : title)")
        out.append("")
        if !body.isEmpty {
            out.append(body)
            out.append("")
        }
        if let context {
            out.append("### What Aviary looked like when this was filed")
            out.append("")
            out.append(context.markdown)
            if let shot = context.screenshot {
                out.append("A screenshot of the window at that moment: `\(shot)`")
                out.append("(Read it with the `ipython` tool if it would help — it is a PNG.)")
                out.append("")
            }
        }
        out.append("### Protocol")
        out.append("")
        out.append("Your standing instructions for this board are in `\(briefPath)`. "
            + "Read them if you have not this session.")
        out.append("")
        out.append("Record progress by appending one JSON object per line to `\(logPath)`:")
        out.append("")
        out.append("```")
        out.append(#"{"v":1,"at":"<ISO8601>","event":"status","id":"\#(id)","status":"claimed|building|done|declined|parked","note":"<why>","by":"agent"}"#)
        out.append(#"{"v":1,"at":"<ISO8601>","event":"note","id":"\#(id)","text":"<what you found>","by":"agent"}"#)
        out.append(#"{"v":1,"at":"<ISO8601>","event":"link","id":"\#(id)","commit":"<sha>"}"#)
        out.append("```")
        out.append("")
        out.append("Append only — never rewrite the file. Aviary is reading it at the same time.")
        return out.joined(separator: "\n")
    }
}

// MARK: - The log

/// One line of the board's history.
public struct WorkshopEvent: Sendable {
    public var at: Date
    public var event: String
    public var id: String
    public var fields: [String: JSONValue]

    public init(at: Date = Date(), event: String, id: String, fields: [String: JSONValue] = [:]) {
        self.at = at
        self.event = event
        self.id = id
        self.fields = fields
    }
}

public enum WorkshopLog {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = iso.date(from: s) { return d }
        // The agent writes these by hand, so accept the plainer form too rather than
        // dropping an event over a missing fractional-seconds field.
        let plain = ISO8601DateFormatter()
        return plain.date(from: s)
    }

    /// Append one event. Creates the directory and file on first use.
    ///
    /// `O_APPEND` on a single `write` of a line-sized buffer is atomic enough for two
    /// writers on one local filesystem, which is the only concurrency this file ever sees.
    public static func append(_ event: WorkshopEvent, repoRoot: URL) throws {
        let dir = Workshop.directory(repoRoot: repoRoot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = Workshop.logURL(repoRoot: repoRoot)

        var obj = event.fields
        obj["v"] = .number(1)
        obj["at"] = .string(iso.string(from: event.at))
        obj["event"] = .string(event.event)
        obj["id"] = .string(event.id)

        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = try enc.encode(JSONValue.object(obj))
        data.append(UInt8(ascii: "\n"))

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Read the log and fold it into the current board.
    ///
    /// Unparseable lines are skipped, not fatal: the agent hand-writes into this file, and
    /// one malformed line must not cost you the board.
    public static func load(repoRoot: URL) -> [WorkshopRequest] {
        let url = Workshop.logURL(repoRoot: repoRoot)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return fold(lines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// The fold, separated from file access so it is testable without a filesystem.
    public static func fold(lines: [String]) -> [WorkshopRequest] {
        var byID: [String: WorkshopRequest] = [:]
        var order: [String] = []

        for line in lines {
            guard let v = JSONValue.parse(Data(line.utf8)),
                  let id = v["id"]?.stringValue, !id.isEmpty
            else { continue }
            let event = v["event"]?.stringValue ?? ""
            let at = parseDate(v["at"]?.stringValue) ?? Date(timeIntervalSince1970: 0)

            switch event {
            case "created":
                guard byID[id] == nil else { break }
                var r = WorkshopRequest(
                    id: id,
                    createdAt: at,
                    title: v["title"]?.stringValue ?? "",
                    body: v["body"]?.stringValue ?? "",
                    kind: WorkshopKind(rawValue: v["kind"]?.stringValue ?? "") ?? .change,
                    status: .open,
                    statusChangedAt: at)
                if let ctx = v["context"] {
                    r.context = decodeContext(ctx, fallbackDate: at)
                }
                byID[id] = r
                order.append(id)

            case "status":
                guard var r = byID[id] else { break }
                if let s = WorkshopStatus(rawValue: v["status"]?.stringValue ?? "") {
                    r.status = s
                    r.statusChangedAt = at
                }
                if let note = v["note"]?.stringValue, !note.isEmpty {
                    r.notes.append(WorkshopNote(
                        at: at, by: v["by"]?.stringValue ?? "agent", text: note))
                }
                byID[id] = r

            case "note":
                guard var r = byID[id] else { break }
                if let text = v["text"]?.stringValue, !text.isEmpty {
                    r.notes.append(WorkshopNote(
                        at: at, by: v["by"]?.stringValue ?? "agent", text: text))
                }
                byID[id] = r

            case "link":
                guard var r = byID[id] else { break }
                if let c = v["commit"]?.stringValue, !c.isEmpty, !r.commits.contains(c) {
                    r.commits.append(c)
                }
                if let s = v["session"]?.stringValue ?? v["sessionFile"]?.stringValue,
                   !s.isEmpty, !r.sessions.contains(s)
                {
                    r.sessions.append(s)
                }
                byID[id] = r

            case "delivered":
                guard var r = byID[id] else { break }
                // `retracted` exists because Aviary once recorded a delivery that had not
                // happened. In an append-only log the correction is a later event that says
                // so, never an edit to the earlier one — the mistake stays visible and the
                // derived state still ends up right.
                r.delivered = !(v["retracted"]?.boolValue ?? false)
                if let s = v["session"]?.stringValue, !s.isEmpty, !r.sessions.contains(s) {
                    r.sessions.append(s)
                }
                byID[id] = r

            default:
                break
            }
        }

        // Newest first: the board is read top-down and the thing you just filed is the
        // thing you want to see.
        return order.compactMap { byID[$0] }.sorted { $0.createdAt > $1.createdAt }
    }

    private static func decodeContext(_ v: JSONValue, fallbackDate: Date) -> WorkshopContext {
        var ctx = WorkshopContext(
            capturedAt: parseDate(v["capturedAt"]?.stringValue) ?? fallbackDate,
            section: v["section"]?.stringValue ?? "",
            sectionSubtitle: v["sectionSubtitle"]?.stringValue ?? "",
            facts: [],
            screenshot: v["screenshot"]?.stringValue)
        for f in v["facts"]?.arrayValue ?? [] {
            guard let label = f["label"]?.stringValue else { continue }
            ctx.facts.append(WorkshopContext.Fact(
                group: f["group"]?.stringValue ?? "Other",
                label: label,
                value: f["value"]?.stringValue ?? ""))
        }
        return ctx
    }

    /// Encode a context for the `created` event.
    public static func encode(_ ctx: WorkshopContext) -> JSONValue {
        var obj: [String: JSONValue] = [
            "capturedAt": .string(iso.string(from: ctx.capturedAt)),
            "section": .string(ctx.section),
            "sectionSubtitle": .string(ctx.sectionSubtitle),
            "facts": .array(ctx.facts.map { f in
                .object([
                    "group": .string(f.group),
                    "label": .string(f.label),
                    "value": .string(f.value),
                ])
            }),
        ]
        if let shot = ctx.screenshot { obj["screenshot"] = .string(shot) }
        return .object(obj)
    }
}

// MARK: - Board

public struct WorkshopBoard: Sendable {
    public var requests: [WorkshopRequest] = []
    public var logExists = false

    public init(requests: [WorkshopRequest] = [], logExists: Bool = false) {
        self.requests = requests
        self.logExists = logExists
    }

    public static func load(repoRoot: URL?) -> WorkshopBoard {
        guard let repoRoot else { return WorkshopBoard() }
        let exists = FileManager.default.fileExists(atPath: Workshop.logURL(repoRoot: repoRoot).path)
        return WorkshopBoard(requests: WorkshopLog.load(repoRoot: repoRoot), logExists: exists)
    }

    public func column(_ c: WorkshopColumn) -> [WorkshopRequest] {
        requests.filter { $0.status.column == c }
    }

    public var openCount: Int { column(.inbox).count }
    public var workingCount: Int { column(.working).count }
    public var doneCount: Int { column(.done).count }

    /// Filed but never handed to a session — the failure this board can actually have.
    public var undeliveredCount: Int {
        requests.filter { $0.status == .open && !$0.delivered }.count
    }
}
