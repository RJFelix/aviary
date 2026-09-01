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

    public var id: String {
        switch self {
        case .canonical(let row): return row.id
        case .legacy(let row): return row.id
        }
    }

    /// The canonical row, when one is available. Legacy rows carry the explicit, partial adapter
    /// projection; callers must inspect its validity/unknown fields before treating it as native.
    public var canonical: CanonicalSessionCatalogSummary? {
        switch self {
        case .canonical(let row): return row
        case .legacy(let row): return row.canonical
        }
    }

    public var title: String {
        switch self {
        case .canonical(let row): return row.title
        case .legacy(let row): return row.title
        }
    }

    /// Compatibility view for the existing UI and destructive catalog operations.
    public var legacySummary: SessionSummary? {
        switch self {
        case .canonical: return nil
        case .legacy(let row): return row.summary
        }
    }

    /// Local filesystem identity, intentionally not the canonical authority-qualified id.
    public var legacyID: String? {
        switch self {
        case .canonical: return nil
        case .legacy(let row): return row.legacyID
        }
    }

    /// The list-facing compatibility value. Native rows survive the migration boundary as
    /// observe-only summaries; they cannot be mistaken for a legacy transcript by callers.
    public var displaySummary: SessionSummary? {
        switch self {
        case .legacy(let row): return row.summary
        case .canonical(let row): return row.displaySummary
        }
    }
}

/// Deterministic, non-trapping index for the production catalog consumer.
///
/// Duplicate IDs indicate competing projections at a boundary (for example, two hosts reporting
/// the same qualified Session identity). The first row in input order remains usable, while every
/// duplicate id is returned as an explicit conflict for diagnostics rather than crashing through
/// `Dictionary(uniqueKeysWithValues:)` or silently replacing a row.
public struct SessionCatalogProjectionIndex: Sendable {
    public let canonicalByID: [String: CanonicalSessionCatalogSummary]
    public let duplicateIDs: [String]
    /// Rows in their first-seen order, with duplicate display identities removed. This is the
    /// sequence the GUI consumes; the map above remains a lookup projection and diagnostics.
    public let displaySummaries: [SessionSummary]

    public init(entries: [SessionCatalogProjection]) {
        var rows: [String: CanonicalSessionCatalogSummary] = [:]
        var duplicates = Set<String>()
        var displayRows: [SessionSummary] = []
        var displayIDs = Set<String>()
        for entry in entries {
            guard let canonical = entry.canonical else { continue }
            if rows[entry.id] != nil {
                duplicates.insert(entry.id)
            } else {
                rows[entry.id] = canonical
            }
            if let summary = entry.displaySummary, displayIDs.insert(summary.id).inserted {
                displayRows.append(summary)
            }
        }
        canonicalByID = rows
        duplicateIDs = duplicates.sorted()
        displaySummaries = displayRows
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
