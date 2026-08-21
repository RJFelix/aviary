import Foundation

// MARK: - Usage

public struct Usage: Sendable, Hashable, Codable {
    public var input: Int = 0
    public var output: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0
    /// Reasoning tokens, when the route reports them. Already counted inside `output`.
    ///
    /// nil means the provider did not say — which is not zero. A route that returns
    /// thinking as text lets you measure it directly; on an encrypted-reasoning route this
    /// is the only evidence the tokens existed.
    public var reasoning: Int?
    public var totalTokens: Int = 0
    public var cost: Cost = Cost()

    public struct Cost: Sendable, Hashable, Codable {
        public var input: Double = 0
        public var output: Double = 0
        public var cacheRead: Double = 0
        public var cacheWrite: Double = 0
        public var total: Double = 0

        public init() {}

        public init(json: JSONValue?) {
            input = json?["input"]?.doubleValue ?? 0
            output = json?["output"]?.doubleValue ?? 0
            cacheRead = json?["cacheRead"]?.doubleValue ?? 0
            cacheWrite = json?["cacheWrite"]?.doubleValue ?? 0
            total = json?["total"]?.doubleValue ?? (input + output + cacheRead + cacheWrite)
        }

        public static func + (a: Cost, b: Cost) -> Cost {
            var c = Cost()
            c.input = a.input + b.input
            c.output = a.output + b.output
            c.cacheRead = a.cacheRead + b.cacheRead
            c.cacheWrite = a.cacheWrite + b.cacheWrite
            c.total = a.total + b.total
            return c
        }
    }

    public init() {}

    public init(json: JSONValue?) {
        guard let json else { return }
        input = json["input"]?.intValue ?? 0
        output = json["output"]?.intValue ?? 0
        cacheRead = json["cacheRead"]?.intValue ?? 0
        cacheWrite = json["cacheWrite"]?.intValue ?? 0
        reasoning = json["reasoning"]?.intValue
        totalTokens = json["totalTokens"]?.intValue ?? (input + output + cacheRead + cacheWrite)
        cost = Cost(json: json["cost"])
    }

    public static func + (a: Usage, b: Usage) -> Usage {
        var u = Usage()
        u.input = a.input + b.input
        u.output = a.output + b.output
        u.cacheRead = a.cacheRead + b.cacheRead
        u.cacheWrite = a.cacheWrite + b.cacheWrite
        // nil + nil stays nil; a known value plus an unknown one is still the known part.
        if a.reasoning != nil || b.reasoning != nil {
            u.reasoning = (a.reasoning ?? 0) + (b.reasoning ?? 0)
        }
        u.totalTokens = a.totalTokens + b.totalTokens
        u.cost = a.cost + b.cost
        return u
    }

    public static func += (a: inout Usage, b: Usage) { a = a + b }

    public var isEmpty: Bool { totalTokens == 0 && cost.total == 0 }

    /// Fraction of input tokens served from cache — the single most useful efficiency
    /// number in a long agent session, and one the harness never displays.
    public var cacheHitRate: Double? {
        let considered = input + cacheRead
        guard considered > 0 else { return nil }
        return Double(cacheRead) / Double(considered)
    }
}

// MARK: - Content blocks

public enum ContentBlock: Sendable, Hashable, Identifiable {
    case text(String)
    case thinking(String)
    case toolCall(ToolCall)
    case image(mimeType: String, base64: String)

    public var id: String {
        switch self {
        case .text(let s): return "t:\(s.hashValue)"
        case .thinking(let s): return "k:\(s.hashValue)"
        case .toolCall(let c): return "c:\(c.id)"
        case .image(let m, let d): return "i:\(m):\(d.prefix(24))"
        }
    }

    public static func parse(_ blocks: JSONValue?) -> [ContentBlock] {
        // A bare string is a valid `content` for user messages.
        if let s = blocks?.stringValue { return s.isEmpty ? [] : [.text(s)] }
        guard let arr = blocks?.arrayValue else { return [] }
        return arr.compactMap { b in
            switch b["type"]?.stringValue {
            case "text":
                let t = b["text"]?.stringValue ?? ""
                return t.isEmpty ? nil : .text(t)
            case "thinking":
                let t = b["thinking"]?.stringValue ?? ""
                return t.isEmpty ? nil : .thinking(t)
            case "toolCall":
                return .toolCall(ToolCall(
                    id: b["id"]?.stringValue ?? UUID().uuidString,
                    name: b["name"]?.stringValue ?? "tool",
                    arguments: b["arguments"] ?? .object([:])))
            case "image":
                return .image(
                    mimeType: b["mimeType"]?.stringValue ?? "image/png",
                    base64: b["data"]?.stringValue ?? "")
            default:
                // Unknown block type: keep any text-ish payload rather than dropping it.
                if let t = b["text"]?.stringValue, !t.isEmpty { return .text(t) }
                return nil
            }
        }
    }
}

public struct ToolCall: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// The harness's only built-in tool is `ipython`, so nearly every tool call in a
    /// transcript is a Python cell. Pull it out for first-class rendering.
    public var pythonCode: String? {
        guard name == "ipython" else { return nil }
        return arguments["code"]?.stringValue
            ?? arguments["cell"]?.stringValue
            ?? arguments["source"]?.stringValue
    }

    /// A one-line label for collapsed rows.
    public var summary: String {
        if let code = pythonCode {
            let firstMeaningful = code
                .split(separator: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty
                    && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            return (firstMeaningful?.trimmingCharacters(in: .whitespaces)) ?? "python"
        }
        if let obj = arguments.objectValue {
            for key in ["command", "path", "query", "prompt", "task", "file_path"] {
                if let v = obj[key]?.stringValue { return v }
            }
        }
        return name
    }
}

// MARK: - Transcript items

/// A renderable transcript row. Deliberately not a 1:1 mapping of session entries: a
/// tool call and its result are two entries but one thing a person wants to look at,
/// and 1,800 `agent_status` entries are one thing (the latest status), not 1,800 rows.
public struct TranscriptItem: Sendable, Identifiable {
    public enum Kind: Sendable {
        case user
        case assistant
        case tool
        case bash
        case custom
        case agentMessage
        case compaction
        case branchSummary
        case stateChange
        case note
    }

    public let id: String
    public let kind: Kind
    public let timestamp: Date
    public var blocks: [ContentBlock] = []
    /// Assistant metadata.
    public var model: String?
    public var provider: String?
    public var usage: Usage?
    public var stopReason: String?
    public var errorMessage: String?
    /// Tool pairing.
    public var toolCall: ToolCall?
    public var toolResultText: String?
    public var toolResultImages: [(mimeType: String, base64: String)] = []
    public var toolIsError: Bool = false
    public var toolDetails: JSONValue?
    public var toolDuration: TimeInterval?
    /// Bash execution.
    public var command: String?
    public var exitCode: Int?
    /// Custom / agent-message metadata.
    public var customType: String?
    public var senderName: String?
    /// Plain text for one-line rows (state changes, notes).
    public var text: String = ""
    /// The raw entry, for the inspector.
    public var raw: JSONValue?

    public init(id: String, kind: Kind, timestamp: Date) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }

    public var plainText: String {
        let fromBlocks = blocks.compactMap { b -> String? in
            switch b {
            case .text(let s): return s
            case .thinking(let s): return s
            default: return nil
            }
        }.joined(separator: "\n")
        if !fromBlocks.isEmpty { return fromBlocks }
        if !text.isEmpty { return text }
        return toolResultText ?? ""
    }
}

// MARK: - Session header & agent status

public struct SessionHeader: Sendable, Hashable {
    public var id: String
    public var version: Int
    public var timestamp: Date
    public var cwd: String
    public var parentSession: String?
    public var rlmDepth: Int
    public var gitCommit: String?
    public var gitBranch: String?

    public init(json: JSONValue, fallbackID: String) {
        id = json["id"]?.stringValue ?? fallbackID
        version = json["version"]?.intValue ?? 1
        timestamp = ISO8601.date(json["timestamp"]?.stringValue) ?? Date.distantPast
        cwd = json["cwd"]?.stringValue ?? ""
        parentSession = json["parentSession"]?.stringValue
        rlmDepth = json["rlmDepth"]?.intValue ?? 0
        gitCommit = json.path("git.commit")?.stringValue
        gitBranch = json.path("git.branch")?.stringValue
    }

    public var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

public struct AgentStatus: Sendable, Hashable {
    public var summary: String
    public var taskState: String?
    public var basedOnMessageCount: Int?
    public var timestamp: Date

    /// `needs_input`, `working`, `done`… mapped to something a UI can colour.
    public var isAwaitingUser: Bool { taskState == "needs_input" }
    public var isDone: Bool { taskState == "done" || taskState == "completed" }
}

// MARK: - Transcript

public struct Transcript: Sendable {
    public var header: SessionHeader
    public var items: [TranscriptItem]
    public var sessionName: String?
    public var status: AgentStatus?
    public var sessionState: String?
    public var usage: Usage
    /// Usage contributed by RLM children and folded into parent messages.
    public var childUsage: Usage
    public var modelChanges: [(date: Date, provider: String, model: String)]
    public var lastModel: String?
    public var lastProvider: String?
    public var counts: Counts
    public var labels: [String: String]
    /// Entries we could not parse. Surfaced rather than hidden, because a nonzero count
    /// here means Aviary is behind a harness format change.
    public var unparsedLines: Int

    public struct Counts: Sendable, Hashable {
        public var user = 0
        public var assistant = 0
        public var toolCalls = 0
        public var toolErrors = 0
        public var bash = 0
        public var compactions = 0
        public var agentMessages = 0
        public var entries = 0
    }

    public var duration: TimeInterval? {
        guard let first = items.first?.timestamp, let last = items.last?.timestamp,
              last > first else { return nil }
        return last.timeIntervalSince(first)
    }
}

// MARK: - Parser

public enum SessionParser {
    /// Parse a session JSONL file into a renderable transcript.
    ///
    /// Sessions are trees (`id`/`parentId`) that branch in place, so the file is not a
    /// conversation — it is every conversation the session has ever had. The active path
    /// is the chain from the last written entry back to the root; anything hanging off an
    /// abandoned branch is deliberately not rendered.
    public static func parse(fileURL: URL) -> Transcript? {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
        return parse(data: data, fallbackID: fileURL.deletingPathExtension().lastPathComponent)
    }

    public static func parse(data: Data, fallbackID: String) -> Transcript? {
        var header: SessionHeader?
        var entries: [(id: String, parentID: String?, value: JSONValue)] = []
        var byID: [String: Int] = [:]
        var unparsed = 0

        // Split on LF only. The harness's own RPC docs call this out: generic line
        // readers that also break on U+2028/U+2029 corrupt records, because those are
        // legal inside JSON strings.
        for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var slice = Data(chunk)
            if slice.last == UInt8(ascii: "\r") { slice.removeLast() }
            guard !slice.isEmpty else { continue }
            guard let v = JSONValue.parse(slice) else { unparsed += 1; continue }
            if v["type"]?.stringValue == "session", header == nil {
                header = SessionHeader(json: v, fallbackID: fallbackID)
                continue
            }
            guard let id = v["id"]?.stringValue else { unparsed += 1; continue }
            byID[id] = entries.count
            entries.append((id: id, parentID: v["parentId"]?.stringValue, value: v))
        }

        guard let header else { return nil }

        // Walk the active branch: last entry → root, then reverse.
        var activeIndices: [Int] = []
        if let lastID = entries.last?.id {
            var cursor: String? = lastID
            var guardCount = 0
            var seen = Set<String>()
            while let cur = cursor, let idx = byID[cur], guardCount < entries.count + 8 {
                if seen.contains(cur) { break }  // malformed cycle; stop rather than hang
                seen.insert(cur)
                activeIndices.append(idx)
                cursor = entries[idx].parentID
                guardCount += 1
            }
            activeIndices.reverse()
        }

        var t = Transcript(
            header: header, items: [], sessionName: nil, status: nil, sessionState: nil,
            usage: Usage(), childUsage: Usage(), modelChanges: [], lastModel: nil,
            lastProvider: nil, counts: Transcript.Counts(), labels: [:], unparsedLines: unparsed)
        t.counts.entries = entries.count

        // Tool results are matched to their call so the UI can show code and output as
        // one unit. Results always follow their call on the active path.
        var pendingCalls: [String: Int] = [:]  // toolCallId -> index in t.items
        var callTimestamps: [String: Date] = [:]

        for idx in activeIndices {
            let e = entries[idx]
            let v = e.value
            let type = v["type"]?.stringValue ?? ""
            let ts = ISO8601.date(v["timestamp"]?.stringValue) ?? header.timestamp

            switch type {
            case "message", "custom_message":
                let msg = type == "custom_message" ? v : (v["message"] ?? .null)
                let role = type == "custom_message" ? "custom" : (msg["role"]?.stringValue ?? "")
                switch role {
                case "user":
                    var item = TranscriptItem(id: e.id, kind: .user, timestamp: ts)
                    item.blocks = ContentBlock.parse(msg["content"])
                    item.raw = v
                    t.items.append(item)
                    t.counts.user += 1

                case "assistant":
                    var item = TranscriptItem(id: e.id, kind: .assistant, timestamp: ts)
                    item.blocks = ContentBlock.parse(msg["content"])
                    item.model = msg["model"]?.stringValue
                    item.provider = msg["provider"]?.stringValue
                    let u = Usage(json: msg["usage"])
                    item.usage = u
                    item.stopReason = msg["stopReason"]?.stringValue
                    item.errorMessage = msg["errorMessage"]?.stringValue
                    item.raw = v
                    t.usage += u
                    t.lastModel = item.model ?? t.lastModel
                    t.lastProvider = item.provider ?? t.lastProvider
                    t.counts.assistant += 1
                    t.items.append(item)

                    // Emit a tool row per call so results have somewhere to land.
                    for block in item.blocks {
                        if case .toolCall(let call) = block {
                            var tool = TranscriptItem(id: "tool:\(call.id)", kind: .tool, timestamp: ts)
                            tool.toolCall = call
                            pendingCalls[call.id] = t.items.count
                            callTimestamps[call.id] = ts
                            t.items.append(tool)
                            t.counts.toolCalls += 1
                        }
                    }

                case "toolResult":
                    let callID = msg["toolCallId"]?.stringValue ?? ""
                    let blocks = ContentBlock.parse(msg["content"])
                    let textOut = blocks.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
                        .joined(separator: "\n")
                    let images = blocks.compactMap { b -> (String, String)? in
                        if case .image(let m, let d) = b { return (m, d) } else { return nil }
                    }
                    let isError = msg["isError"]?.boolValue ?? false
                    if isError { t.counts.toolErrors += 1 }

                    if let slot = pendingCalls[callID], t.items.indices.contains(slot) {
                        t.items[slot].toolResultText = Ansi.strip(textOut)
                        t.items[slot].toolResultImages = images.map { (mimeType: $0.0, base64: $0.1) }
                        t.items[slot].toolIsError = isError
                        t.items[slot].toolDetails = msg["details"]
                        if let started = callTimestamps[callID] {
                            t.items[slot].toolDuration = ts.timeIntervalSince(started)
                        }
                        pendingCalls.removeValue(forKey: callID)
                    } else {
                        // Orphaned result (call lived on a pruned branch). Still show it.
                        var item = TranscriptItem(id: e.id, kind: .tool, timestamp: ts)
                        item.toolCall = ToolCall(
                            id: callID, name: msg["toolName"]?.stringValue ?? "tool",
                            arguments: .object([:]))
                        item.toolResultText = Ansi.strip(textOut)
                        item.toolIsError = isError
                        item.raw = v
                        t.items.append(item)
                    }

                case "bashExecution":
                    var item = TranscriptItem(id: e.id, kind: .bash, timestamp: ts)
                    item.command = msg["command"]?.stringValue
                    item.text = Ansi.strip(msg["output"]?.stringValue ?? "")
                    item.exitCode = msg["exitCode"]?.intValue
                    item.raw = v
                    t.items.append(item)
                    t.counts.bash += 1

                case "custom":
                    let ctype = (type == "custom_message"
                        ? v["customType"]?.stringValue
                        : msg["customType"]?.stringValue) ?? "extension"
                    let content = (type == "custom_message" ? v["content"] : msg["content"])
                    let isAgentMessage = ctype == "agent_message"
                    var item = TranscriptItem(
                        id: e.id, kind: isAgentMessage ? .agentMessage : .custom, timestamp: ts)
                    item.customType = ctype
                    item.blocks = ContentBlock.parse(content)
                    item.text = content?.textContent ?? ""
                    item.senderName = AgentMessageHeader.senderName(from: item.text)
                    item.raw = v
                    if isAgentMessage { t.counts.agentMessages += 1 }
                    t.items.append(item)

                case "compactionSummary":
                    var item = TranscriptItem(id: e.id, kind: .compaction, timestamp: ts)
                    item.text = msg["summary"]?.stringValue ?? ""
                    item.raw = v
                    t.items.append(item)
                    t.counts.compactions += 1

                case "branchSummary":
                    var item = TranscriptItem(id: e.id, kind: .branchSummary, timestamp: ts)
                    item.text = msg["summary"]?.stringValue ?? ""
                    item.raw = v
                    t.items.append(item)

                default:
                    break
                }

            case "compaction":
                var item = TranscriptItem(id: e.id, kind: .compaction, timestamp: ts)
                item.text = v["summary"]?.stringValue ?? ""
                item.usage = {
                    var u = Usage()
                    u.totalTokens = v["tokensBefore"]?.intValue ?? 0
                    return u
                }()
                item.raw = v
                t.items.append(item)
                t.counts.compactions += 1

            case "branch_summary":
                var item = TranscriptItem(id: e.id, kind: .branchSummary, timestamp: ts)
                item.text = v["summary"]?.stringValue ?? ""
                item.raw = v
                t.items.append(item)

            case "model_change":
                let provider = v["provider"]?.stringValue ?? ""
                let model = v["modelId"]?.stringValue ?? ""
                t.modelChanges.append((date: ts, provider: provider, model: model))
                t.lastModel = model
                t.lastProvider = provider
                var item = TranscriptItem(id: e.id, kind: .stateChange, timestamp: ts)
                item.text = "Model → \(provider)/\(model)"
                item.raw = v
                t.items.append(item)

            case "thinking_level_change":
                var item = TranscriptItem(id: e.id, kind: .stateChange, timestamp: ts)
                item.text = "Thinking → \(v["thinkingLevel"]?.stringValue ?? "?")"
                item.raw = v
                t.items.append(item)

            case "service_tier_change":
                var item = TranscriptItem(id: e.id, kind: .stateChange, timestamp: ts)
                item.text = "Service tier → \(v["serviceTier"]?.stringValue ?? "?")"
                item.raw = v
                t.items.append(item)

            case "session_info":
                t.sessionName = v["name"]?.stringValue ?? t.sessionName

            case "session_state":
                t.sessionState = v.path("state.status")?.stringValue ?? t.sessionState

            case "agent_status":
                // Thousands of these accumulate; only the latest is meaningful.
                t.status = AgentStatus(
                    summary: v.path("status.summary")?.stringValue ?? "",
                    taskState: v.path("status.taskState")?.stringValue,
                    basedOnMessageCount: v.path("status.basedOnMessageCount")?.intValue,
                    timestamp: ts)

            case "child_usage_attributed":
                t.childUsage += Usage(json: v["childUsage"])

            case "label":
                if let target = v["targetId"]?.stringValue {
                    if let label = v["label"]?.stringValue {
                        t.labels[target] = label
                    } else {
                        t.labels.removeValue(forKey: target)
                    }
                }

            case "git_state", "custom":
                break  // bookkeeping; not shown inline

            default:
                break
            }
        }

        return t
    }
}

// MARK: - Helpers

public enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }

    public static func string(_ d: Date) -> String { withFraction.string(from: d) }
}

/// ANSI escape removal.
///
/// The agent's tool is a shell-backed IPython kernel, so tool output is full of colour
/// codes (`ls`, `git`, `pytest`). Rendering them literally is unreadable; the codes are
/// stripped once, at parse time.
public enum Ansi {
    public static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return normalizeCR(s) }
        var out = String()
        out.reserveCapacity(s.count)
        var iter = s.makeIterator()
        var pending: Character?
        while let c = pending ?? iter.next() {
            pending = nil
            guard c == "\u{1B}" else { out.append(c); continue }
            guard let next = iter.next() else { break }
            if next == "[" {
                // CSI: consume parameter/intermediate bytes up to the final byte.
                while let p = iter.next() {
                    if ("\u{40}"..."\u{7E}").contains(p) { break }
                }
            } else if next == "]" {
                // OSC: runs until BEL or ST (ESC \).
                while let p = iter.next() {
                    if p == "\u{07}" { break }
                    if p == "\u{1B}" { _ = iter.next(); break }
                }
            } else if next == "\u{1B}" {
                pending = next
            }
        }
        return normalizeCR(out)
    }

    /// Terminal output arrives with CRLF and bare CR (progress bars). Keep it as lines.
    private static func normalizeCR(_ s: String) -> String {
        guard s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Agent-to-agent messages arrive as a `custom_message` whose body starts with a
/// generated provenance header. Pull the sender out so the UI can show "from
/// models-providers" instead of a wall of routing metadata.
enum AgentMessageHeader {
    static func senderName(from text: String) -> String? {
        guard let range = text.range(of: "[from ") else { return nil }
        let after = text[range.upperBound...]
        guard let close = after.firstIndex(of: "]") else { return nil }
        let raw = String(after[..<close])
        // Shapes seen: "child:models-providers", "parent", "peer:name".
        if let colon = raw.firstIndex(of: ":") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw
    }
}

// MARK: - Injected context

/// Separates a user prompt from context that a hook or extension prepended to it.
///
/// Harnesses inject context by wrapping it in a pseudo-XML block and gluing it to the front
/// of the user's message — `<duckbill-knowledge>…</duckbill-knowledge>`,
/// `<system-reminder>…</system-reminder>`, and whatever an extension invents. The result is
/// that a session's "first message" is several kilobytes of machine-generated preamble, so
/// every session in a list ends up with the same title and the actual question is invisible.
/// Splitting them apart makes the list readable and lets the transcript show the injection
/// as something you can expand rather than something you must scroll past.
public enum PromptText {
    public struct Block: Sendable, Hashable, Identifiable {
        public var id: String { tag + String(body.prefix(24)) }
        public var tag: String
        public var body: String
    }

    public struct Split: Sendable {
        public var injected: [Block] = []
        public var userText: String = ""

        public var hasInjection: Bool { !injected.isEmpty }
    }

    /// Peel leading (and trailing) wrapper blocks off a prompt.
    public static func split(_ text: String) -> Split {
        var result = Split()
        var rest = Substring(text)

        func peelLeading() -> Bool {
            let trimmed = rest.drop(while: { $0.isWhitespace || $0.isNewline })
            guard trimmed.first == "<" else { return false }
            // Read the tag name.
            let afterAngle = trimmed.dropFirst()
            guard let firstChar = afterAngle.first, firstChar.isLetter else { return false }
            let name = afterAngle.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            guard !name.isEmpty else { return false }
            let afterName = afterAngle.dropFirst(name.count)
            guard afterName.first == ">" else { return false }

            let closing = "</\(name)>"
            guard let closeRange = trimmed.range(of: closing) else { return false }

            let openEnd = afterName.index(after: afterName.startIndex)
            let inner = trimmed[openEnd..<closeRange.lowerBound]
            result.injected.append(Block(
                tag: String(name),
                body: String(inner).trimmingCharacters(in: .whitespacesAndNewlines)))
            rest = trimmed[closeRange.upperBound...]
            return true
        }

        var guardCount = 0
        while peelLeading(), guardCount < 8 { guardCount += 1 }

        result.userText = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)

        // If peeling consumed everything, the wrapper *was* the message — put it back
        // rather than showing an empty prompt.
        if result.userText.isEmpty, let first = result.injected.first {
            result.userText = first.body
            result.injected.removeFirst()
        }
        return result
    }

    /// Just the part a person wrote.
    public static func userFacing(_ text: String) -> String {
        split(text).userText
    }
}
