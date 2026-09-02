import Foundation

/// A catalog row at the migration boundary.
///
/// Canonical rows are the eventual source for the session inbox. The current on-disk store is
/// still a legacy JSONL transcript, so this boundary keeps that fact explicit instead of making
/// `SessionSummary` look like a native Session/Work projection. The local legacy id remains
/// separate from the authority-qualified canonical id because artifacts and live joins still use
/// the filename stem.
public enum SessionCatalogProjection: Sendable, Hashable, Identifiable {
    case canonical(CanonicalSessionCatalogSummary)
    case legacy(LegacySessionCatalogProjection)
    /// A native canonical session that still has a legacy transcript. The legacy summary retains
    /// transcript/action identity, while the canonical summary is authoritative for lifecycle,
    /// model, attention, and other native facts exposed by the display projection.
    case companion(CompanionSessionCatalogProjection)

    /// Pair a native row with its legacy compatibility row only when both names identify the
    /// same session. The labeled factory keeps callers from accidentally constructing a pair
    /// around unrelated rows.
    public static func companion(
        canonical: CanonicalSessionCatalogSummary,
        legacySummary: SessionSummary
    ) -> SessionCatalogProjection? {
        CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacySummary)
            .map { Self.companion($0) }
    }

    public var id: String {
        switch self {
        case .canonical(let row): return row.id
        case .legacy(let row): return row.id
        case .companion(let row): return row.id
        }
    }

    /// The canonical row, when one is available. Legacy rows carry the explicit, partial adapter
    /// projection; callers must inspect its validity/unknown fields before treating it as native.
    public var canonical: CanonicalSessionCatalogSummary? {
        switch self {
        case .canonical(let row): return row
        case .legacy(let row): return row.canonical
        case .companion(let row): return row.canonical
        }
    }

    public var title: String {
        switch self {
        case .canonical(let row): return row.title
        case .legacy(let row): return row.title
        case .companion(let row): return row.title
        }
    }

    /// Compatibility view for the existing UI and destructive catalog operations.
    public var legacySummary: SessionSummary? {
        switch self {
        case .canonical: return nil
        case .legacy(let row): return row.summary
        case .companion(let row): return row.summary
        }
    }

    /// Local filesystem identity, intentionally not the canonical authority-qualified id.
    public var legacyID: String? {
        switch self {
        case .canonical: return nil
        case .legacy(let row): return row.legacyID
        case .companion(let row): return row.legacyID
        }
    }

    /// The list-facing compatibility value. Native rows survive the migration boundary as
    /// observe-only summaries; they cannot be mistaken for a legacy transcript by callers.
    public var displaySummary: SessionSummary? {
        switch self {
        case .legacy(let row): return row.summary
        case .canonical(let row): return row.displaySummary
        case .companion(let row): return row.displaySummary
        }
    }
}

/// The migration-boundary value for one session represented by both the native catalog and the
/// legacy transcript scanner. This is deliberately failable: pairing rows with different local
/// session identities would make a plausible-looking row whose transcript actions target the
/// wrong session.
public struct CompanionSessionCatalogProjection: Sendable, Hashable, Identifiable {
    public let canonical: CanonicalSessionCatalogSummary
    /// Untouched compatibility record used to locate transcript/artifact actions.
    public let summary: SessionSummary
    /// List/action value with native Session facts overlaid where the projection is complete.
    public let displaySummary: SessionSummary

    public var id: String { summary.id }
    public var legacyID: String { summary.id }
    public var title: String { displaySummary.title }

    public init?(
        canonical: CanonicalSessionCatalogSummary,
        legacySummary: SessionSummary
    ) {
        guard canonical.session.sessionID == legacySummary.id else { return nil }
        self.canonical = canonical
        self.summary = legacySummary
        var display = legacySummary
        if canonical.sessionStructuralIntegrityValid, canonical.sessionSemanticProjectionValid {
            if canonical.unknownDomains.contains(.session) {
                // Keep the raw transcript in `summary`, but do not let it refill native fields
                // whose meaning may have changed under an event this reader does not know.
                display.name = "Session details unknown"
                display.cwd = ""
                display.gitBranch = nil
                display.firstPrompt = ""
                display.lastAssistantText = ""
                display.sessionState = nil
                display.model = nil
                display.provider = nil
                display.usage = Usage()
                display.childUsage = Usage()
                display.counts = Transcript.Counts()
                display.status = nil
                display.rlmDepth = 0
                display.parentSessionPath = nil
                display.childCount = 0
            } else {
                if !canonical.title.isEmpty { display.name = canonical.title }
                display.sessionState = canonical.lifecycle.rawValue
                display.model = canonical.sessionModelID
                    ?? (canonical.modelIDs.count == 1 ? canonical.modelIDs.first : nil)
                // Timeline does not yet carry provider identity. Never pair a native model fact
                // with the legacy transcript's potentially stale provider as if observed.
                display.provider = nil
                // Legacy task-state heuristics are not native attention truth.
                display.status = nil
            }
        }
        self.displaySummary = display
    }

    /// Convenience spelling for callers constructing the enum case without exposing the
    /// failable identity check at every call site.
    public static func make(
        canonical: CanonicalSessionCatalogSummary,
        legacySummary: SessionSummary
    ) -> SessionCatalogProjection? {
        CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacySummary)
            .map(SessionCatalogProjection.companion)
    }
}

/// Deterministic, non-trapping index for the production catalog consumer.
///
/// Duplicate IDs indicate competing projections at a boundary (for example, two hosts reporting
/// the same qualified Session identity). Every conflicting row is withheld from display and
/// canonical lookup, while the duplicate id remains explicit for diagnostics rather than crashing
/// through `Dictionary(uniqueKeysWithValues:)` or silently selecting a winner.
public struct SessionCatalogProjectionIndex: Sendable {
    public let canonicalByID: [String: CanonicalSessionCatalogSummary]
    public let duplicateIDs: [String]
    /// Rows in their first-seen order, with duplicate display identities removed. This is the
    /// sequence the GUI consumes; the map above remains a lookup projection and diagnostics.
    public let displaySummaries: [SessionSummary]
    /// The same conflict-free rows as their migration-boundary projections. Consumers that need
    /// bounded native fields (rather than the compatibility summaries) use this exact sequence.
    public let displayEntries: [SessionCatalogProjection]

    public init(entries: [SessionCatalogProjection]) {
        let counts = Dictionary(grouping: entries, by: \.id).mapValues(\.count)
        let duplicateSet = Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
        var rows: [String: CanonicalSessionCatalogSummary] = [:]
        var displayRows: [SessionSummary] = []
        var displayEntries: [SessionCatalogProjection] = []
        for entry in entries {
            guard !duplicateSet.contains(entry.id) else { continue }
            guard let canonical = entry.canonical else { continue }
            rows[entry.id] = canonical
            displayEntries.append(entry)
            if let summary = entry.displaySummary { displayRows.append(summary) }
        }
        canonicalByID = rows
        duplicateIDs = duplicateSet.sorted()
        displaySummaries = displayRows
        self.displayEntries = displayEntries
    }
}

private extension CanonicalSessionCatalogSummary {
    var displaySummary: SessionSummary {
        var summary = SessionSummary(
            id: id, headerID: nil, fileURL: nil,
            name: title.isEmpty ? "Untitled session" : title, cwd: "", gitBranch: nil,
            createdAt: .distantPast, updatedAt: .distantPast, byteSize: 0,
            provider: nil, model: modelIDs.first,
            usage: Usage(), childUsage: Usage(), counts: Transcript.Counts(),
            firstPrompt: title, lastAssistantText: "", status: nil,
            sessionState: lifecycle.rawValue, rlmDepth: 0, parentSessionPath: nil)
        summary.isCanonicalOnly = true
        summary.isArchived = lifecycle == .archived
        return summary
    }
}

/// Explicit compatibility projection for a legacy transcript summary.
public struct LegacySessionCatalogProjection: Sendable, Hashable, Identifiable {
    public let summary: SessionSummary
    public let canonical: CanonicalSessionCatalogSummary
    /// The filename stem used by artifacts, kernel state, wire logs, and live-run joins.
    public let legacyID: String
    /// Domains that the legacy transcript scanner does not semantically reconstruct.
    public let unknownDomains: [TimelineDomain]

    public var id: String { legacyID }
    public var title: String {
        canonical.title.isEmpty ? summary.title : canonical.title
    }

    init(summary: SessionSummary, canonical: CanonicalSessionCatalogSummary) {
        self.summary = summary
        self.canonical = canonical
        self.legacyID = summary.id
        self.unknownDomains = canonical.unknownDomains
    }
}

/// Adapter used by the production catalog scan until native Session journals replace the legacy
/// transcript store. It never exposes raw JSON or namespace representations.
public enum LegacySessionCatalogAdapter {
    public static func project(
        summary: SessionSummary,
        authorityID: String
    ) -> SessionCatalogProjection {
        let canonical = CanonicalSessionCatalogSummary.legacyCompatibility(
            summary: summary, authorityID: authorityID)
        return .legacy(LegacySessionCatalogProjection(summary: summary, canonical: canonical))
    }
}
