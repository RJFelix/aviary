import Foundation

// MARK: - settings.json

/// The harness's user settings, read and written in place.
public struct HarnessSettings: Sendable {
    public var defaultProvider: String?
    public var defaultModel: String?
    public var defaultThinkingLevel: String?
    public var recentModels: [String]
    public var packages: [String]
    public var hideThinkingBlock: Bool?
    public var raw: JSONValue
    public var fileURL: URL
    public var exists: Bool

    public static func load(home: AgentHome) -> HarnessSettings {
        let url = home.settingsFile
        guard let data = FileManager.default.contents(atPath: url.path),
              let v = JSONValue.parse(data)
        else {
            return HarnessSettings(
                defaultProvider: nil, defaultModel: nil, defaultThinkingLevel: nil,
                recentModels: [], packages: [], hideThinkingBlock: nil,
                raw: .object([:]), fileURL: url, exists: false)
        }
        return HarnessSettings(
            defaultProvider: v["defaultProvider"]?.stringValue,
            defaultModel: v["defaultModel"]?.stringValue,
            defaultThinkingLevel: v["defaultThinkingLevel"]?.stringValue,
            recentModels: (v["recentModels"]?.arrayValue ?? []).compactMap(\.stringValue),
            packages: (v["packages"]?.arrayValue ?? []).compactMap(\.stringValue),
            hideThinkingBlock: v["hideThinkingBlock"]?.boolValue,
            raw: v, fileURL: url, exists: true)
    }

    public var defaultModelQualified: String? {
        switch (defaultProvider, defaultModel) {
        case (let p?, let m?): return "\(p)/\(m)"
        case (nil, let m?): return m
        default: return nil
        }
    }

    /// Patch a single top-level key, preserving everything else in the file.
    public func write(key: String, value: JSONValue?) throws {
        var obj = raw.objectValue ?? [:]
        if let value { obj[key] = value } else { obj.removeValue(forKey: key) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(JSONValue.object(obj))
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Skills

/// Which engines will actually load a skill.
///
/// Not a detail. The engine bundle's own skills are written for the harness's IPython
/// namespace — `rlm_heartbeat.create`, `goal.create`, `compact.run` — and the harness loads
/// them itself, where those names exist. Aviary's own engines never load them: all three run
/// paths pass `enginePackageRoot: nil`, and a skill telling an Aviary agent to call
/// `rlm_heartbeat.create` would be the exact inverse of an undescribed builtin.
///
/// So the two sets are both correct, for different runtimes, and the only thing that was wrong
/// was a screen showing their union as one list.
public enum SkillReach: String, Sendable, Hashable, CaseIterable {
    /// Found in a project or user directory. Every engine reads these.
    case everyEngine
    /// Shipped inside the engine package, and loaded only by that engine.
    case bundledEngineOnly

    public var label: String {
        switch self {
        case .everyEngine: return "Every engine"
        case .bundledEngineOnly: return "Bundled engine only"
        }
    }

    public var explanation: String {
        switch self {
        case .everyEngine:
            return "Read from a project or user skills directory, so an Aviary run describes "
                + "it to the model when the gate selects it."
        case .bundledEngineOnly:
            return "Ships inside the engine package and is loaded by that engine itself. "
                + "Aviary's own engines never see it — which is correct: these skills teach "
                + "the harness's Python namespace, not Aviary's builtins."
        }
    }
}

/// A skill discovered on disk, with its frontmatter read.
public struct SkillEntry: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public var name: String
    public var description: String
    public var url: URL
    public var sourceLabel: String
    /// Precedence group — the harness resolves same-named skills by source priority.
    public var precedence: Int
    public var bodyLength: Int
    public var hasPythonBacking: Bool
    public var allowedTools: [String]
    /// Which engines load it. Set by discovery from the root it was found under.
    public var reach: SkillReach = .everyEngine

    public var directory: URL {
        url.lastPathComponent == "SKILL.md" ? url.deletingLastPathComponent() : url
    }
}

/// Where a search for skills, prompts, and extensions looked, and what it found.
public struct LibrarySource: Sendable, Identifiable, Hashable {
    public var id: String { url.path + label }
    public var label: String
    public var url: URL
    public var exists: Bool
    public var count: Int
    public var precedence: Int
}

public struct PromptTemplate: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public var name: String
    public var url: URL
    public var sourceLabel: String
    public var firstLine: String
    public var byteSize: Int
}

public struct ExtensionEntry: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public var name: String
    public var url: URL
    public var sourceLabel: String
    public var byteSize: Int
    /// Event hooks the file appears to register, scraped from its source. A rough but
    /// genuinely useful summary — an extension that hooks `before_agent_start` behaves
    /// very differently from one that only handles `input`.
    public var hooks: [String]
}

public struct PackageEntry: Sendable, Identifiable, Hashable {
    public var id: String { spec }
    /// The entry as written in settings.json.
    public var spec: String
    public var resolvedURL: URL?
    public var name: String?
    public var version: String?
    public var isLocalPath: Bool
    public var exists: Bool
    public var skillCount: Int
    public var extensionCount: Int
    public var promptCount: Int
}

/// Discovers everything the harness would load, and says where each thing came from.
///
/// Written natively because "why is this skill not showing up?" is a question about
/// *paths*, and the fastest possible answer is a list of every directory that was
/// searched, whether it exists, and how many things it contributed — including the ones
/// that contributed nothing. The harness can tell you what it loaded; it can't easily
/// tell you what it looked at.
public struct Library: Sendable {
    public init() {}

    public var skills: [SkillEntry] = []
    /// The skills an Aviary run can actually be given.
    public var reachableSkills: [SkillEntry] { skills.filter { $0.reach == .everyEngine } }
    /// Discovered, shown, and loaded only by the engine that ships them.
    public var engineOnlySkills: [SkillEntry] { skills.filter { $0.reach == .bundledEngineOnly } }
    public var prompts: [PromptTemplate] = []
    public var extensions: [ExtensionEntry] = []
    public var packages: [PackageEntry] = []
    public var sources: [LibrarySource] = []

    public static func discover(
        home: AgentHome,
        settings: HarnessSettings,
        projectRoot: URL?,
        enginePackageRoot: URL?,
        /// Defaulted rather than derived inside, so a test can describe a whole machine.
        /// Without the seam every test of discovery also reads whatever skills the person
        /// running it happens to have installed, and asserts nothing reliable.
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Library {
        var lib = Library()
        let fm = FileManager.default

        // Skill roots, highest precedence first — mirrors the harness's documented order.
        // url, label, precedence, allowRootMD, reach
        var skillRoots: [(URL, String, Int, Bool, SkillReach)] = []
        if let projectRoot {
            skillRoots.append((projectRoot.appending(path: ".prime/agent/skills"),
                               "Project (.prime/agent/skills)", 0, true, .everyEngine))
            skillRoots.append((projectRoot.appending(path: ".agents/skills"),
                               "Project (.agents/skills)", 1, false, .everyEngine))
        }
        skillRoots.append((home.skillsDir, "User (~/.prime/agent/skills)", 2, true, .everyEngine))
        skillRoots.append((userHome.appending(path: ".agents/skills"),
                           "User (~/.agents/skills)", 3, false, .everyEngine))
        if let enginePackageRoot {
            skillRoots.append((enginePackageRoot.appending(path: "skills"),
                               "Built-in (engine)", 9, true, .bundledEngineOnly))
        }

        for (root, label, precedence, allowRootMD, reach) in skillRoots {
            let found = scanSkills(root: root, label: label, precedence: precedence,
                                   allowRootMarkdown: allowRootMD, reach: reach)
            lib.skills += found
            lib.sources.append(LibrarySource(
                label: "Skills — \(label)", url: root,
                exists: fm.fileExists(atPath: root.path), count: found.count,
                precedence: precedence))
        }

        // Packages from settings.json. Relative entries resolve against the agent dir.
        for spec in settings.packages {
            var entry = PackageEntry(
                spec: spec, resolvedURL: nil, name: nil, version: nil,
                isLocalPath: spec.hasPrefix(".") || spec.hasPrefix("/") || spec.hasPrefix("~"),
                exists: false, skillCount: 0, extensionCount: 0, promptCount: 0)
            if entry.isLocalPath {
                let expanded = (spec as NSString).expandingTildeInPath
                let url = expanded.hasPrefix("/")
                    ? URL(fileURLWithPath: expanded)
                    : URL(fileURLWithPath: expanded, relativeTo: home.root).standardizedFileURL
                entry.resolvedURL = url
                entry.exists = fm.fileExists(atPath: url.path)
                if entry.exists {
                    if let pkgData = fm.contents(atPath: url.appending(path: "package.json").path),
                       let pkg = JSONValue.parse(pkgData)
                    {
                        entry.name = pkg["name"]?.stringValue
                        entry.version = pkg["version"]?.stringValue
                    }
                    let pkgSkills = scanSkills(
                        root: url.appending(path: "skills"),
                        label: "Package \(entry.name ?? spec)", precedence: 5,
                        allowRootMarkdown: true)
                    lib.skills += pkgSkills
                    entry.skillCount = pkgSkills.count

                    let pkgExtensions = scanExtensions(
                        root: url.appending(path: "extensions"),
                        label: "Package \(entry.name ?? spec)")
                    lib.extensions += pkgExtensions
                    entry.extensionCount = pkgExtensions.count

                    let pkgPrompts = scanPrompts(
                        root: url.appending(path: "prompts"),
                        label: "Package \(entry.name ?? spec)")
                    lib.prompts += pkgPrompts
                    entry.promptCount = pkgPrompts.count
                }
            }
            lib.packages.append(entry)
        }

        // User-level prompts and extensions.
        let userPrompts = scanPrompts(root: home.promptsDir, label: "User")
        lib.prompts += userPrompts
        lib.sources.append(LibrarySource(
            label: "Prompts — User", url: home.promptsDir,
            exists: fm.fileExists(atPath: home.promptsDir.path),
            count: userPrompts.count, precedence: 2))

        let userExtensions = scanExtensions(root: home.extensionsDir, label: "User")
        lib.extensions += userExtensions
        lib.sources.append(LibrarySource(
            label: "Extensions — User", url: home.extensionsDir,
            exists: fm.fileExists(atPath: home.extensionsDir.path),
            count: userExtensions.count, precedence: 2))

        // Deduplicate skills by name, keeping the highest-precedence one — the same rule
        // the harness applies, so the list shows what would actually load.
        var seen: [String: SkillEntry] = [:]
        for s in lib.skills.sorted(by: { $0.precedence < $1.precedence }) {
            if seen[s.name] == nil { seen[s.name] = s }
        }
        lib.skills = seen.values.sorted { $0.name < $1.name }
        lib.prompts.sort { $0.name < $1.name }
        lib.extensions.sort { $0.name < $1.name }
        return lib
    }

    static func scanSkills(
        root: URL, label: String, precedence: Int, allowRootMarkdown: Bool,
        reach: SkillReach = .everyEngine
    ) -> [SkillEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var out: [SkillEntry] = []

        // Directory skills: <root>/<name>/SKILL.md, at any depth.
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.lastPathComponent == "SKILL.md" {
                if let e = parseSkill(url: url, label: label, precedence: precedence,
                                      reach: reach) {
                    out.append(e)
                }
            }
        }
        // Bare `.md` files count as skills only in the `.prime/agent/skills` style roots.
        if allowRootMarkdown,
           let entries = try? fm.contentsOfDirectory(
               at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
            for url in entries where url.pathExtension == "md" {
                if let e = parseSkill(url: url, label: label, precedence: precedence,
                                      reach: reach) {
                    out.append(e)
                }
            }
        }
        return out
    }

    static func parseSkill(
        url: URL, label: String, precedence: Int, reach: SkillReach = .everyEngine
    ) -> SkillEntry? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fm = Frontmatter.parse(text)
        let dir = url.deletingLastPathComponent()
        let hasPython = FileManager.default.fileExists(
            atPath: dir.appending(path: "scripts").path)
            || (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .contains(where: { $0.hasSuffix(".py") }) ?? false
        let fallbackName = url.lastPathComponent == "SKILL.md"
            ? dir.lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        return SkillEntry(
            name: fm.values["name"] ?? fallbackName,
            description: fm.values["description"] ?? "",
            url: url,
            sourceLabel: label,
            precedence: precedence,
            bodyLength: fm.body.count,
            hasPythonBacking: hasPython,
            allowedTools: (fm.values["allowed-tools"] ?? fm.values["allowedTools"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            reach: reach)
    }

    static func scanPrompts(root: URL, label: String) -> [PromptTemplate] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return [] }
        return entries.filter { $0.pathExtension == "md" }.compactMap { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let first = text.split(whereSeparator: \.isNewline)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            return PromptTemplate(
                name: "/" + url.deletingPathExtension().lastPathComponent,
                url: url, sourceLabel: label,
                firstLine: String(first.prefix(200)),
                byteSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func scanExtensions(root: URL, label: String) -> [ExtensionEntry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return [] }
        let knownHooks = [
            "session_start", "session_before_switch", "before_agent_start", "agent_end",
            "input", "message_start", "message_end", "tool_execution_start",
            "tool_execution_end", "before_compaction", "resources_discover",
        ]
        return entries.filter { ["ts", "js", "mjs"].contains($0.pathExtension) }.map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return ExtensionEntry(
                name: url.deletingPathExtension().lastPathComponent,
                url: url, sourceLabel: label,
                byteSize: text.utf8.count,
                hooks: knownHooks.filter { text.contains("\"\($0)\"") || text.contains("'\($0)'") })
        }
    }
}

/// Minimal YAML frontmatter reader — enough for Agent Skills' flat `key: value` blocks.
public enum Frontmatter {
    public struct Result {
        public var values: [String: String] = [:]
        public var body: String = ""
    }

    public static func parse(_ text: String) -> Result {
        var r = Result()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            r.body = text
            return r
        }
        var i = 1
        var lastKey: String?
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { i += 1; break }
            if let colon = raw.firstIndex(of: ":"), !raw.hasPrefix(" "), !raw.hasPrefix("-") {
                let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(raw[raw.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1)
                    || (value.hasPrefix("'") && value.hasSuffix("'") && value.count > 1)
                {
                    value = String(value.dropFirst().dropLast())
                }
                r.values[key] = value
                lastKey = key
            } else if !line.isEmpty, let k = lastKey {
                // Folded continuation line.
                r.values[k] = ((r.values[k] ?? "") + " " + line).trimmingCharacters(in: .whitespaces)
            }
            i += 1
        }
        r.body = lines[i...].joined(separator: "\n")
        return r
    }
}
