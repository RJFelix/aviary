import Foundation

/// How often each builtin and skill actually got used, read back out of the trajectories.
///
/// The Library can say what is *available*. It could not say what anyone *reaches for* — which
/// is the more interesting question, and the one that decides whether a name is earning its
/// place in the tool description or just costing tokens on every request.
///
/// Derived from the transcripts rather than recorded into a database, deliberately. The
/// transcripts are already the durable, append-only record; a second store would be a second
/// source of truth that can disagree with the first, and this codebase has already paid for
/// that once (an append-only daemon ledger against a writer-owned artifact, disagreeing). A
/// recorder would also only ever capture *future* use, so the reader below would have to exist
/// anyway for the backfill — and then there would be two ways to answer one question. Measured
/// cost of the full scan is reported in `scanDuration` so the decision stays falsifiable: if it
/// stops being cheap, the fix is a cache keyed on file size and mtime, not a database.
///
/// **What the numbers mean, exactly.** A "call" is a textual call site in the source of a
/// `python` cell — `name(` not preceded by a letter, digit, underscore, or dot, so `foo.sh(`
/// and `my_sh(` do not count but a mention inside a string or comment does. The count is
/// therefore an upper bound on real invocations, and the UI says so. Counting cells instead
/// would understate a loop; counting at runtime would mean instrumenting the kernel, which
/// costs more than the question is worth.
public struct LibraryUsage: Sendable {
    public init() {}

    public struct Day: Sendable, Identifiable, Hashable {
        public var id: Date { day }
        public var day: Date
        public var count: Int

        public init(day: Date, count: Int) {
            self.day = day
            self.count = count
        }
    }

    public struct Series: Sendable, Identifiable, Hashable {
        public var id: String { name }
        public var name: String
        /// Textual call sites across every cell.
        public var calls: Int
        /// Cells containing at least one — immune to a call inside a loop body being counted
        /// once while another is counted twenty times.
        public var cells: Int
        public var sessions: Int
        public var lastUsed: Date?
        /// Ascending, and sparse: a day with no use is absent rather than zero.
        public var byDay: [Day] = []

        public init(name: String, calls: Int = 0, cells: Int = 0, sessions: Int = 0) {
            self.name = name
            self.calls = calls
            self.cells = cells
            self.sessions = sessions
        }

        public var wasEverUsed: Bool { calls > 0 }

        /// A dense window ending today, so a chart's x-axis is time rather than a list of the
        /// days that happened to have activity.
        public func days(last window: Int, calendar: Calendar = .current, now: Date = Date())
            -> [Day]
        {
            let today = calendar.startOfDay(for: now)
            let counts = Dictionary(byDay.map { ($0.day, $0.count) }, uniquingKeysWith: +)
            return (0..<max(1, window)).reversed().compactMap { back in
                guard let day = calendar.date(byAdding: .day, value: -back, to: today)
                else { return nil }
                return Day(day: day, count: counts[day] ?? 0)
            }
        }
    }

    public var builtins: [Series] = []
    public var skills: [Series] = []
    /// Reported because every number above is a fraction of it.
    public var cellsScanned = 0
    public var transcriptsScanned = 0
    public var scanDuration: TimeInterval = 0
    public var firstActivity: Date?
    public var lastActivity: Date?

    public func builtin(named name: String) -> Series? { builtins.first { $0.name == name } }
    public func skill(named name: String) -> Series? { skills.first { $0.name == name } }

    // MARK: - Scanning

    /// Every transcript Aviary owns, parents and sub-agents alike.
    ///
    /// Sub-agent work is not a footnote — a fan-out can outweigh its parent — so the scan
    /// walks `session-artifacts/` as well, where children write their own transcripts.
    public static func transcripts(home: AgentHome) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        if let top = try? fm.contentsOfDirectory(
            at: home.sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
            found += top.filter { $0.pathExtension == "jsonl" }
        }
        if let walker = fm.enumerator(
            at: home.artifactsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                found.append(url)
            }
        }
        return found
    }

    public static func scan(
        home: AgentHome,
        builtins builtinNames: [String],
        skills: [SkillEntry],
        calendar: Calendar = .current
    ) -> LibraryUsage {
        scan(transcripts: transcripts(home: home), builtins: builtinNames, skills: skills,
             calendar: calendar)
    }

    public static func scan(
        transcripts urls: [URL],
        builtins builtinNames: [String],
        skills: [SkillEntry],
        calendar: Calendar = .current
    ) -> LibraryUsage {
        let started = Date()
        var usage = LibraryUsage()
        usage.transcriptsScanned = urls.count

        var builtinTally = builtinNames.reduce(into: [String: Tally]()) { $0[$1] = Tally() }
        var skillTally = skills.reduce(into: [String: Tally]()) { $0[$1.name] = Tally() }
        // A skill is credited when a cell names its *path*, not its name: several of the
        // bundled skills are called `edit`, `goal`, `compact` — ordinary English words that
        // would match half the corpus on a bare-name search.
        let builtinNeedles: [(name: String, needle: [UInt8])] =
            builtinNames.map { ($0, Array($0.utf8)) }
        let skillNeedles: [(name: String, needles: [String])] = skills.map { skill in
            let dir = skill.directory.lastPathComponent
            return (skill.name, ["skills/" + dir, skill.directory.path, skill.url.path])
        }

        for (index, url) in urls.enumerated() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let sessionKey = index
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // The cheap prefilter earns its keep: most lines in a transcript are prose,
                // and JSON-parsing all of them costs more than the whole rest of the scan.
                guard line.contains("\"toolCall\"") else { continue }
                guard let entry = JSONValue.parse(Data(line.utf8)) else { continue }
                let at = ISO8601.date(entry["timestamp"]?.stringValue)
                guard let blocks = entry["message"]?["content"]?.arrayValue else { continue }
                for block in blocks {
                    guard block["type"]?.stringValue == "toolCall",
                          let code = block["arguments"]?["code"]?.stringValue
                            ?? block["arguments"]?["cell"]?.stringValue
                            ?? block["arguments"]?["source"]?.stringValue
                    else { continue }
                    usage.cellsScanned += 1
                    if let at {
                        usage.firstActivity = min(usage.firstActivity ?? at, at)
                        usage.lastActivity = max(usage.lastActivity ?? at, at)
                    }
                    let day = at.map { calendar.startOfDay(for: $0) }
                    // Converted once per cell rather than once per name: with six builtins
                    // that alone was most of the scan's time.
                    let bytes = Array(code.utf8)
                    for (name, needle) in builtinNeedles {
                        let hits = callSites(of: needle, in: bytes)
                        guard hits > 0 else { continue }
                        builtinTally[name]?.record(
                            calls: hits, at: at, day: day, session: sessionKey)
                    }
                    // Most cells never mention a skill at all, and this prefilter is the
                    // difference between one substring search and fourteen.
                    if code.contains("skills/") || code.contains("SKILL.md") {
                        for (name, needles) in skillNeedles
                        where needles.contains(where: { code.contains($0) }) {
                            skillTally[name]?.record(
                                calls: 1, at: at, day: day, session: sessionKey)
                        }
                    }
                }
            }
        }

        usage.builtins = builtinNames.map { builtinTally[$0]?.series(name: $0) ?? Series(name: $0) }
        usage.skills = skills.map { skillTally[$0.name]?.series(name: $0.name)
            ?? Series(name: $0.name) }
        usage.scanDuration = Date().timeIntervalSince(started)
        return usage
    }

    /// Call sites of `needle` in a cell's UTF-8 bytes.
    ///
    /// Written by hand rather than with a regex because it runs once per builtin per cell and
    /// the whole scan is meant to stay cheap enough that nobody is tempted to add a database.
    static func callSites(of needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count > needle.count else { return 0 }
        var count = 0
        var i = 0
        let limit = haystack.count - needle.count
        outer: while i <= limit {
            guard haystack[i] == needle[0] else { i += 1; continue }
            for k in 1..<needle.count where haystack[i + k] != needle[k] {
                i += 1
                continue outer
            }
            // `foo.sh(` and `my_sh(` are somebody else's function with a colliding suffix.
            let before: UInt8? = i > 0 ? haystack[i - 1] : nil
            if let before, isNameByte(before) || before == UInt8(ascii: ".") {
                i += 1
                continue
            }
            // Allow whitespace between the name and its parenthesis; nothing else.
            var j = i + needle.count
            while j < haystack.count,
                  haystack[j] == UInt8(ascii: " ") || haystack[j] == UInt8(ascii: "\t") { j += 1 }
            if j < haystack.count, haystack[j] == UInt8(ascii: "(") { count += 1 }
            i += needle.count
        }
        return count
    }

    /// Convenience for tests and callers that have a string in hand.
    static func callSites(of name: String, in source: String) -> Int {
        callSites(of: Array(name.utf8), in: Array(source.utf8))
    }

    private static func isNameByte(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            || b == UInt8(ascii: "_")
    }

    private struct Tally {
        var calls = 0
        var cells = 0
        var sessions: Set<Int> = []
        var days: [Date: Int] = [:]
        var lastUsed: Date?

        mutating func record(calls hits: Int, at: Date?, day: Date?, session: Int) {
            calls += hits
            cells += 1
            sessions.insert(session)
            if let day { days[day, default: 0] += hits }
            if let at { lastUsed = max(lastUsed ?? at, at) }
        }

        func series(name: String) -> Series {
            var s = Series(name: name, calls: calls, cells: cells, sessions: sessions.count)
            s.lastUsed = lastUsed
            s.byDay = days.map { Day(day: $0.key, count: $0.value) }.sorted { $0.day < $1.day }
            return s
        }
    }
}

// MARK: - Which skills teach which builtin

/// The link between a skill and the builtins it actually tells the agent to call.
///
/// Built by reading the skills, not by declaring the relationship in a table: a table would be
/// a third thing to keep in step with both the catalogue and the files on disk, and it would
/// go stale silently. Reading is cheap and cannot lie.
///
/// It answers a question that turns out to matter. A skill written for a *different* runtime's
/// namespace will happily instruct the model to call names Aviary never binds — which is the
/// exact inverse of the bug `Builtins` exists to prevent, and just as expensive to debug from
/// the transcript.
public struct SkillBuiltinIndex: Sendable {
    public init() {}

    /// Builtin name → the skills that reference it, most references first.
    public var byBuiltin: [String: [String]] = [:]
    /// Skills that reference no builtin at all.
    public var unattached: [String] = []

    public func skills(for builtin: String) -> [String] { byBuiltin[builtin] ?? [] }

    /// Reads each skill's own text — its Markdown plus any Python sitting beside it, since a
    /// python-backed skill does its real instructing in the module rather than the prose.
    public static func build(skills: [SkillEntry], builtins: [String]) -> SkillBuiltinIndex {
        var index = SkillBuiltinIndex()
        var scored: [String: [(skill: String, hits: Int)]] = [:]
        let needles = builtins.map { ($0, Array($0.utf8)) }

        for skill in skills {
            let text = sources(of: skill)
            let bytes = Array(text.utf8)
            var any = false
            for (name, needle) in needles {
                let hits = LibraryUsage.callSites(of: needle, in: bytes)
                guard hits > 0 else { continue }
                any = true
                scored[name, default: []].append((skill.name, hits))
            }
            if !any { index.unattached.append(skill.name) }
        }

        index.byBuiltin = scored.mapValues { entries in
            entries.sorted { ($0.hits, $1.skill) > ($1.hits, $0.skill) }.map(\.skill)
        }
        return index
    }

    /// A skill's own files, concatenated and capped.
    ///
    /// The cap exists because a skill directory can contain a vendored dependency tree, and a
    /// name that appears in somebody's vendored library is not the skill teaching it.
    private static let byteCap = 256 * 1024

    private static func sources(of skill: SkillEntry) -> String {
        var text = (try? String(contentsOf: skill.url, encoding: .utf8)) ?? ""
        let fm = FileManager.default
        let dir = skill.directory
        for sub in ["", "scripts", "src"] {
            let root = sub.isEmpty ? dir : dir.appending(path: sub, directoryHint: .isDirectory)
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for url in entries where url.pathExtension == "py" {
                guard text.utf8.count < byteCap else { return text }
                text += "\n" + ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
        }
        return text
    }
}
