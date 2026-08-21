import Foundation

/// One record written by the `wire-log` harness extension.
public struct WireRecord: Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case request
        case response
        case unknown
    }

    public var id: Int { seq }
    public var seq: Int
    public var at: Date
    public var kind: Kind
    /// The exact object handed to the provider.
    public var payload: JSONValue?
    public var status: Int?
    public var headers: [String: String]

    /// Path of the session transcript this request belonged to, as reported by the harness.
    public var sessionFile: String?

    /// The session id, derived from that path.
    ///
    /// Deliberately *not* the payload's `prompt_cache_key`. That field looks exactly like a
    /// session id and is not one — measured on a real run it was `01a0222d-510c…` while the
    /// session written to disk was `01a0222d-4ec9…`. Attributing logs by it silently
    /// associates every recording with a session that does not exist.
    public var sessionID: String? {
        guard let sessionFile, !sessionFile.isEmpty else { return nil }
        return URL(fileURLWithPath: sessionFile).deletingPathExtension().lastPathComponent
    }

    public var modelID: String? {
        payload?["model"]?.stringValue
    }
}

/// A named part of a request payload, with its measured size.
///
/// Sizes are characters, because that is the only thing measurable without the provider's
/// tokenizer. Token figures are derived and labelled as estimates everywhere they surface;
/// the *shares* are exact, which is what makes the breakdown trustworthy — combined with
/// the real input-token total from the response, a share turns into a defensible number.
public struct PayloadSegment: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var characters: Int
    /// Full text, when this segment is text rather than structure.
    public var text: String?
    public var children: [PayloadSegment] = []
    /// Marks segments Aviary recognised rather than merely measured.
    public var kind: Kind = .other

    public enum Kind: String, Sendable {
        case systemPrompt
        case contextFile
        case skills
        case skill
        case tools
        case tool
        case message
        case parameters
        case other
    }

    public var estimatedTokens: Int { max(0, characters / 4) }

    /// Share of the whole payload, 0…1.
    public func share(of total: Int) -> Double {
        total > 0 ? Double(characters) / Double(total) : 0
    }

    /// The estimate rescaled to a known real total — the honest per-part number.
    public func scaledTokens(payloadCharacters: Int, actualTokens: Int) -> Int {
        guard payloadCharacters > 0, actualTokens > 0 else { return estimatedTokens }
        return Int((Double(characters) / Double(payloadCharacters)) * Double(actualTokens))
    }

    public var flattened: [PayloadSegment] {
        [self] + children.flatMap(\.flattened)
    }
}

public struct PayloadAnalysis: Sendable {
    public var totalCharacters: Int
    public var segments: [PayloadSegment]
    /// Provider-shape label, e.g. "openai-responses".
    public var shape: String
    public var modelID: String?

    public var estimatedTokens: Int { max(0, totalCharacters / 4) }

    public func segment(kind: PayloadSegment.Kind) -> PayloadSegment? {
        segments.flatMap(\.flattened).first { $0.kind == kind }
    }
}

/// Reads a wire log and decomposes payloads into something a person can read.
public enum WireLog {
    // MARK: Reading

    public static func read(url: URL) -> [WireRecord] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        var out: [WireRecord] = []
        for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let v = JSONValue.parse(Data(chunk)) else { continue }
            let kind = WireRecord.Kind(rawValue: v["kind"]?.stringValue ?? "") ?? .unknown
            out.append(WireRecord(
                seq: v["seq"]?.intValue ?? out.count,
                at: ISO8601.date(v["at"]?.stringValue) ?? .distantPast,
                kind: kind,
                payload: v["payload"],
                status: v["status"]?.intValue,
                headers: (v["headers"]?.objectValue ?? [:]).compactMapValues(\.stringValue),
                sessionFile: v["sessionFile"]?.stringValue))
        }
        return out
    }

    /// Where Aviary keeps wire logs it recorded.
    public static var directory: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support
            .appending(path: "Aviary", directoryHint: .isDirectory)
            .appending(path: "wire", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func path(forRun id: UUID) -> URL {
        directory.appending(path: "run-\(id.uuidString).jsonl")
    }

    /// Maps recorded logs to the sessions they belong to.
    ///
    /// Built by reading each file's first record only. The responses API carries
    /// `prompt_cache_key`, which the harness sets to the session id, so one line is enough
    /// to attribute a whole log — and a directory that accumulates one file per run should
    /// not cost a full parse of every payload to search.
    public struct Index: Sendable {
        public init() {}

        /// session id → log files, newest first.
        public var bySession: [String: [URL]] = [:]
        /// Logs whose payloads carry no session id (routes without a cache key).
        public var unattributed: [URL] = []

        public func logs(forSession id: String) -> [URL] { bySession[id] ?? [] }
        public var sessionCount: Int { bySession.count }
        public var fileCount: Int {
            bySession.values.reduce(0) { $0 + $1.count } + unattributed.count
        }
    }

    public static func buildIndex() -> Index {
        var index = Index()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return index }

        let sorted = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a > b
            }

        for url in sorted {
            if let session = firstSessionID(in: url) {
                index.bySession[session, default: []].append(url)
            } else {
                index.unattributed.append(url)
            }
        }
        return index
    }

    /// The session id from the first record that names one, without parsing the whole file.
    static func firstSessionID(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        // A single record is large (a system prompt is tens of kilobytes), so read in
        // generous chunks and stop at the first complete line.
        for _ in 0..<8 {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                if let v = JSONValue.parse(line),
                   let path = v["sessionFile"]?.stringValue, !path.isEmpty
                {
                    return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                }
                return nil
            }
        }
        return nil
    }

    /// Records for one session, across every log that names it.
    public static func records(forSession id: String, index: Index) -> [WireRecord] {
        index.logs(forSession: id)
            .flatMap { read(url: $0) }
            .filter { $0.sessionID == nil || $0.sessionID == id }
            .sorted { ($0.at, $0.seq) < ($1.at, $1.seq) }
    }

    // MARK: Analysis

    public static func analyse(payload: JSONValue) -> PayloadAnalysis {
        let total = characters(of: payload)
        var segments: [PayloadSegment] = []
        var shape = "unknown"
        var accountedKeys = Set<String>()

        // openai-responses / openai-codex-responses: `instructions` + `input`.
        if let instructions = payload["instructions"]?.stringValue {
            shape = "openai-responses"
            segments.append(systemPromptSegment(instructions))
            accountedKeys.insert("instructions")
        }
        // anthropic-messages: `system` (string or blocks) + `messages`.
        else if let system = payload["system"] {
            shape = "anthropic-messages"
            let text = system.stringValue ?? system.textContent
            segments.append(systemPromptSegment(text))
            accountedKeys.insert("system")
        }

        // Messages, under whichever key this provider uses.
        for key in ["input", "messages", "contents"] {
            guard let messages = payload[key]?.arrayValue else { continue }
            if shape == "unknown" {
                shape = key == "contents" ? "google-generative-ai" : "openai-completions"
            }
            // A system-role first message is the system prompt on completions-style routes.
            var rest = messages
            if segments.isEmpty, let first = messages.first,
               ["system", "developer"].contains(first["role"]?.stringValue ?? "")
            {
                segments.append(systemPromptSegment(first["content"]?.textContent ?? ""))
                rest = Array(messages.dropFirst())
            }
            var children: [PayloadSegment] = []
            for (i, m) in rest.enumerated() {
                let role = m["role"]?.stringValue ?? "message"
                let chars = characters(of: m)
                children.append(PayloadSegment(
                    id: "\(key).\(i)",
                    label: "[\(i)] \(role)",
                    characters: chars,
                    text: m["content"]?.textContent,
                    kind: .message))
            }
            segments.append(PayloadSegment(
                id: key,
                label: "\(key) — \(rest.count) message\(rest.count == 1 ? "" : "s")",
                characters: characters(of: payload[key]!),
                children: children,
                kind: .message))
            accountedKeys.insert(key)
            break
        }

        // Tool schemas.
        if let tools = payload["tools"]?.arrayValue {
            var children: [PayloadSegment] = []
            for (i, t) in tools.enumerated() {
                let name = t["name"]?.stringValue
                    ?? t.path("function.name")?.stringValue
                    ?? "tool \(i)"
                children.append(PayloadSegment(
                    id: "tools.\(i)",
                    label: name,
                    characters: characters(of: t),
                    text: t["description"]?.stringValue
                        ?? t.path("function.description")?.stringValue,
                    kind: .tool))
            }
            segments.append(PayloadSegment(
                id: "tools",
                label: "tools — \(tools.count) schema\(tools.count == 1 ? "" : "s")",
                characters: characters(of: payload["tools"]!),
                children: children.sorted { $0.characters > $1.characters },
                kind: .tools))
            accountedKeys.insert("tools")
        }

        // Everything left: sampling parameters, flags, cache keys.
        if let obj = payload.objectValue {
            let remaining = obj.filter { !accountedKeys.contains($0.key) }
            if !remaining.isEmpty {
                let chars = remaining.reduce(0) { $0 + $1.key.count + characters(of: $1.value) + 4 }
                segments.append(PayloadSegment(
                    id: "parameters",
                    label: "parameters — \(remaining.count) field\(remaining.count == 1 ? "" : "s")",
                    characters: chars,
                    text: remaining.keys.sorted().joined(separator: ", "),
                    kind: .parameters))
            }
        }

        return PayloadAnalysis(
            totalCharacters: total,
            segments: segments.sorted { $0.characters > $1.characters },
            shape: shape,
            modelID: payload["model"]?.stringValue)
    }

    // MARK: System prompt segmentation

    /// Splits an assembled system prompt into the pieces that went into it.
    ///
    /// The harness composes this from its base instructions, per-topic sections marked with
    /// `# ` headings, the contents of every discovered AGENTS.md / CLAUDE.md, and an
    /// `<available_skills>` block holding one description per discovered skill. On a machine
    /// with a large skill library that last block dominates everything else — which is
    /// invisible until you break it out, and is the usual answer to "why is my input so big".
    static func systemPromptSegment(_ text: String) -> PayloadSegment {
        var children: [PayloadSegment] = []
        var remainder = text

        // Pull the skills catalogue out first: it is the biggest single thing and its
        // internal `#` characters would confuse heading detection.
        if let block = enclosedBlock(in: text, tag: "available_skills") {
            remainder = text.replacingOccurrences(of: block, with: "")
            children.append(skillsSegment(block))
        }

        // Then split what's left on top-level markdown headings — except inside a context
        // file, whose own body is markdown and routinely starts with an `# ` heading of its
        // own. Attributing that to a new section instead of to the file it came from
        // misplaces the largest thing a project contributes, so a `## /path` marker takes
        // precedence and swallows headings until the next file or the end.
        let lines = remainder.split(separator: "\n", omittingEmptySubsequences: false)
        var current = "(base instructions)"
        var buffer: [String] = []
        var sections: [(String, String)] = []
        var insideContextFile = false

        func flush() {
            let body = buffer.joined(separator: "\n")
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append((current, body))
            }
            buffer.removeAll()
        }

        for line in lines {
            if line.hasPrefix("## /") {
                // "## /path/to/AGENTS.md" — a discovered context file.
                flush()
                current = String(line.dropFirst(3))
                insideContextFile = true
            } else if line.hasPrefix("# "), !insideContextFile {
                flush()
                current = String(line.dropFirst(2))
            } else {
                buffer.append(String(line))
            }
        }
        flush()

        for (i, section) in sections.enumerated() {
            let isFile = section.0.hasPrefix("/")
            children.append(PayloadSegment(
                id: "system.\(i)",
                label: isFile ? URL(fileURLWithPath: section.0).lastPathComponent : section.0,
                characters: section.1.count + section.0.count,
                text: section.1,
                kind: isFile ? .contextFile : .systemPrompt))
        }

        return PayloadSegment(
            id: "system",
            label: "system prompt",
            characters: text.count,
            text: text,
            children: children.sorted { $0.characters > $1.characters },
            kind: .systemPrompt)
    }

    static func skillsSegment(_ block: String) -> PayloadSegment {
        // Entries look like <skill><name>…</name><description>…</description></skill>, but
        // the exact tag set has changed between releases — so split on name tags, which
        // have been stable, and measure the span up to the next one.
        var children: [PayloadSegment] = []
        let names = enclosedValues(in: block, tag: "name")
        if !names.isEmpty {
            let spans = spans(in: block, tag: "name")
            for (i, name) in names.enumerated() {
                let start = spans[i].lowerBound
                let end = i + 1 < spans.count ? spans[i + 1].lowerBound : block.endIndex
                children.append(PayloadSegment(
                    id: "skill.\(i)",
                    label: name,
                    characters: block.distance(from: start, to: end),
                    text: String(block[start..<end]),
                    kind: .skill))
            }
        }
        return PayloadSegment(
            id: "skills",
            label: "available skills — \(max(children.count, names.count))",
            characters: block.count,
            text: children.isEmpty ? block : nil,
            children: children.sorted { $0.characters > $1.characters },
            kind: .skills)
    }

    // MARK: Text helpers

    static func enclosedBlock(in text: String, tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.lowerBound..<close.upperBound])
    }

    static func enclosedValues(in text: String, tag: String) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        while let open = text.range(of: "<\(tag)>", range: cursor..<text.endIndex),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        {
            out.append(String(text[open.upperBound..<close.lowerBound]))
            cursor = close.upperBound
        }
        return out
    }

    static func spans(in text: String, tag: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var cursor = text.startIndex
        while let open = text.range(of: "<\(tag)>", range: cursor..<text.endIndex) {
            out.append(open)
            cursor = open.upperBound
        }
        return out
    }

    /// Serialized size. The unit the provider bills is tokens, but characters are the only
    /// thing measurable here without its tokenizer.
    static func characters(of value: JSONValue) -> Int {
        if let s = value.stringValue { return s.count }
        return value.compactJSON.count
    }
}
