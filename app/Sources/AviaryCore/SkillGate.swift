import Foundation

/// Which skills a request carries.
///
/// The harness injected every installed skill's description into every request: measured at 68
/// skills, 46,713 characters, **62.7% of the input tokens on a two-message run**, paid whether
/// or not any skill was used. That is the single largest measured waste in the system it
/// replaces, so this is the one place Aviary should not simply match the harness.
///
/// The design is a budget with a visible remainder rather than a filter that silently drops
/// things. Two rules, both learned from what went wrong elsewhere:
///
/// 1. **Nothing is hidden.** Skills that miss the budget are still *listed* — one line each,
///    name and a few words — with an instruction saying how to read the full description. A
///    pruned skill the model cannot see and cannot ask for is silent capability loss, and the
///    failure looks like the model being stupid rather than the harness being wrong.
/// 2. **Ranking is by relevance and recency, never alphabetical.** The harness's continual
///    harness sorted by path and truncated at six, so the newest and most relevant entry was
///    routinely invisible. Sorting arbitrarily is worse than not sorting, because it looks
///    deliberate.
public struct SkillGate: Sendable {
    /// Character budget for full descriptions. Roughly 2,000 tokens — a twentieth of what the
    /// harness spent, and enough for the handful of skills any one task needs.
    public var budget: Int
    /// Always included regardless of relevance, for skills that are part of how you work
    /// rather than a tool for a particular job.
    public var pinned: Set<String>

    public init(budget: Int = 8_000, pinned: Set<String> = []) {
        self.budget = budget
        self.pinned = pinned
    }

    public struct Selection: Sendable {
        public var included: [SkillEntry]
        public var listed: [SkillEntry]
        public var charactersUsed: Int
        /// What the harness would have spent on the same set, for comparison.
        public var charactersIfAllIncluded: Int

        public var savedCharacters: Int { max(0, charactersIfAllIncluded - charactersUsed) }
    }

    /// Score skills against the prompt and fill the budget.
    ///
    /// Deliberately a keyword overlap rather than an embedding: it needs no index, no model
    /// call and no dependency, it is explainable when it picks wrong, and the alternative was
    /// not "something smarter" but "everything, always". A cheap ranking that keeps the tail
    /// visible beats a good ranking that hides it.
    public func select(skills: [SkillEntry], prompt: String, cwd: String) -> Selection {
        // The prompt and the working directory are scored separately, and the directory counts
        // for a quarter. Weighting them equally meant every skill mentioning the project name
        // matched everything: "what is 2+2?" in the Skyway checkout pulled in fifteen skills,
        // which is the harness's failure in miniature.
        let promptTerms = Self.terms(in: prompt)
        let contextTerms = Self.terms(in: cwd).subtracting(promptTerms)
        let scored = skills.map { skill -> (skill: SkillEntry, score: Double) in
            if pinned.contains(skill.name) { return (skill, .greatestFiniteMagnitude) }
            let score = Self.score(skill, terms: promptTerms)
                + 0.25 * Self.score(skill, terms: contextTerms)
            return (skill, score)
        }
        // Ties broken by recency, so a freshly written skill beats a stale one of equal
        // relevance rather than losing to it on name — which is the mistake the continual
        // harness made, and the reason its newest entry was routinely the invisible one.
        let modified = Dictionary(uniqueKeysWithValues: skills.map {
            ($0.id, (try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.modificationDate]
                as? Date) ?? Date.distantPast)
        })
        let ranked = scored.sorted {
            $0.score != $1.score
                ? $0.score > $1.score
                : (modified[$0.skill.id] ?? .distantPast) > (modified[$1.skill.id] ?? .distantPast)
        }

        var included: [SkillEntry] = []
        var listed: [SkillEntry] = []
        var used = 0
        for entry in ranked {
            let cost = entry.skill.name.count + entry.skill.description.count + 8
            // A weak match never earns a full slot. Without a floor, a budget with few skills
            // installed silently reverts to the harness's behaviour of sending everything —
            // and a single incidental word in a description is not relevance.
            if used + cost <= budget,
               entry.score >= Self.relevanceFloor || pinned.contains(entry.skill.name)
            {
                included.append(entry.skill)
                used += cost
            } else {
                listed.append(entry.skill)
            }
        }
        return Selection(
            included: included, listed: listed, charactersUsed: used,
            charactersIfAllIncluded: skills.reduce(0) { $0 + $1.name.count + $1.description.count + 8 })
    }

    /// The block that goes in the system prompt.
    public func render(_ selection: Selection) -> String {
        guard !selection.included.isEmpty || !selection.listed.isEmpty else { return "" }
        var out = ["## Skills", ""]
        if !selection.included.isEmpty {
            out.append("Likely relevant to this task:")
            out.append("")
            for skill in selection.included {
                out.append("- **\(skill.name)** — \(skill.description)")
                out.append("  `\(skill.url.path)`")
            }
        }
        if !selection.listed.isEmpty {
            out.append("")
            out.append("Also installed, described in one line each. Read the file for the full "
                + "instructions before using one:")
            out.append("")
            // Names and paths only. The tail stays visible — a capability the model cannot see
            // and cannot ask for is a capability that does not exist.
            for skill in selection.listed {
                out.append("- \(skill.name) · `\(skill.url.path)`")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Below this, a skill is listed rather than described. One incidental term match scores
    /// 1.0, so the floor sits just above it: a name hit, or two description hits, or one of
    /// each.
    static let relevanceFloor = 1.5

    // MARK: Scoring

    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "your", "you", "are", "was",
        "但", "use", "using", "make", "made", "get", "got", "can", "will", "should", "would",
        "what", "when", "where", "which", "how", "why", "all", "any", "some", "then", "than",
        "have", "has", "had", "not", "but", "its", "it's", "about", "please", "need", "want",
    ]

    static func terms(in text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) })
    }

    static func score(_ skill: SkillEntry, terms: Set<String>) -> Double {
        let haystack = Self.terms(in: "\(skill.name) \(skill.description)")
        guard !haystack.isEmpty else { return 0 }
        var score = 0.0
        for term in terms {
            if haystack.contains(term) {
                score += 1
            } else if term.count > 4, haystack.contains(where: { $0.hasPrefix(term) || term.hasPrefix($0) }) {
                // Partial credit for a stem match: "compaction" should find "compact".
                score += 0.5
            }
        }
        // A name hit is worth more than a description hit — a skill called `clickhouse` is a
        // better answer to a ClickHouse question than one that mentions it in passing.
        let nameTerms = Self.terms(in: skill.name)
        score += 2.0 * Double(terms.intersection(nameTerms).count)
        return score
    }
}
