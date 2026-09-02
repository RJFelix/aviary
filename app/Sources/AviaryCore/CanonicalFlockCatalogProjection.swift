import Foundation

/// Legacy AgentTree child IDs are only unique within their parent Session. This namespace keeps
/// selection and SwiftUI row identity distinct across roots, including duplicate child IDs.
public enum LegacyFlockIdentity {
    public static func rowID(parentSessionID: String, childID: String) -> String {
        "legacy:\(parentSessionID.utf8.count):\(parentSessionID):child:\(childID.utf8.count):\(childID)"
    }
}

/// The Flock-facing projection of the local Timeline catalog.
///
/// Work remains the unit of identity: a Work may be visible before a Session attaches, and a
/// Work may be attached to more than one Session. Child ids are only unique within a Work, so
/// the projection qualifies them with the Work identity before a UI uses them as row ids.
public struct CanonicalFlockCatalogProjection: Codable, Hashable, Sendable, Identifiable {
    public struct AttentionStatus: Codable, Hashable, Sendable {
        public let requirement: CanonicalAttentionRequirement
        public let attention: SessionAttention?
    }

    public struct SessionLink: Codable, Hashable, Sendable, Identifiable {
        public let session: SessionRef
        public let journal: JournalRef
        public let title: String
        /// Nil means the Session/Work attachment could not prove an effective attention value.
        public let attention: SessionAttention?

        public var id: String { journal.stableKey }

        fileprivate init(summary: CanonicalSessionCatalogSummary) {
            session = summary.session
            journal = summary.journal
            title = summary.title.isEmpty ? "Session details unknown" : summary.title
            attention = summary.effectiveAttention
        }
    }

    public struct Child: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let childID: String
        public let name: String?
        public let state: String
        public let source: EventRef

        fileprivate init(workIdentity: String, node: CanonicalFlockNode) {
            id = "\(workIdentity)/child:\(node.childID.utf8.count):\(node.childID)"
            childID = node.childID
            name = node.name
            state = node.state
            source = node.source
        }
    }

    public let id: String
    public let locatorID: String?
    public let work: WorkRef?
    public let journal: JournalRef?
    public let workHost: WorkHostRef?
    public let cursor: JournalCursor?
    public let lifecycle: WorkLifecycle?
    public let execution: WorkExecution?
    public let modelID: String?
    public let sessions: [SessionLink]
    public let children: [Child]
    public let isAvailable: Bool
    /// Child lifecycle is partial when the Work reducer retained an unknown runtime event.
    public let childLifecycleAvailable: Bool
    public let unknownEventRefs: [EventRef]
    public let unknownDomains: [TimelineDomain]
    public let unavailableReason: String?

    /// Flock can retain legacy AgentTree roots while a native companion is absent.  This
    /// explicit provenance set is supplied by SessionCatalog's companion matcher; canonical
    /// projection keys are deliberately not consulted because they also contain legacy adapters.
    public static func legacyCompatibilityRootIDs(
        _ parentSessionIDs: [String], nativeCompanionLegacyIDs: Set<String>
    ) -> [String] {
        parentSessionIDs.filter { !nativeCompanionLegacyIDs.contains($0) }
    }

    /// One known Work is running only when its own execution or an exact, complete child
    /// projection proves that fact. Unknown/partial child state never implies liveness.
    public var isRunning: Bool {
        guard isAvailable else { return false }
        if let execution, [.preparing, .running, .canceling].contains(execution) { return true }
        guard childLifecycleAvailable else { return false }
        return children.contains { ["running", "active"].contains($0.state.lowercased()) }
    }

    /// Summarize every attached Session without allowing an earlier `.none` to hide a later
    /// request. A proven request wins; otherwise any unknown stays unknown rather than becoming
    /// no-attention. The ordering only chooses which proven request to label in the compact UI.
    public var attentionStatus: AttentionStatus {
        Self.summarizeAttention(sessions.map(\.attention))
    }

    public static func summarizeAttention(_ values: [SessionAttention?]) -> AttentionStatus {
        let priority: [SessionAttention] = [.error, .confirmation, .input, .review]
        let known = values.compactMap { $0 }
        if let attention = priority.first(where: { known.contains($0) }) {
            return AttentionStatus(requirement: .required, attention: attention)
        }
        if values.contains(where: { $0 == nil }) {
            return AttentionStatus(requirement: .unknown, attention: nil)
        }
        return AttentionStatus(requirement: .none, attention: SessionAttention.none)
    }

    /// Count attention once per authority-qualified Session journal, even when a Session is
    /// attached to multiple Work rows.
    public static func attentionSessionCount(
        _ works: [CanonicalFlockCatalogProjection]
    ) -> Int {
        Dictionary(grouping: works.flatMap(\.sessions), by: \.id).values.filter { links in
            links.contains { $0.attention.map { $0 != .none } ?? false }
        }.count
    }

    public init(workRow: LocalTimelineCatalog.WorkRow,
                sessions: [CanonicalSessionCatalogSummary] = []) {
        let workIdentity = workRow.work.map(Self.qualifiedWork) ?? workRow.id
        id = workIdentity
        locatorID = workRow.locatorID
        work = workRow.work
        journal = workRow.journal
        workHost = workRow.workHost
        cursor = workRow.cursor
        lifecycle = workRow.lifecycle
        execution = workRow.execution
        modelID = workRow.modelID
        let links = sessions.filter { summary in
            summary.work.contains { $0.isAttached && $0.work == workRow.work }
        }.map(SessionLink.init)
        self.sessions = Dictionary(grouping: links, by: \.id).compactMap { $0.value.first }
            .sorted { $0.id < $1.id }
        // Child lifecycle producers declare Work and external-effects domains. Runtime is also
        // conservative here because older readers may encode child state there; any unknown
        // affected domain means the visible child set is not complete.
        let unknownChildDomain = workRow.unknownDomains.contains(.work)
            || workRow.unknownDomains.contains(.externalEffects)
            || workRow.unknownDomains.contains(.runtime)
        childLifecycleAvailable = workRow.isAvailable && !unknownChildDomain
            && workRow.canonicalFlock?.isAvailable == true
        children = childLifecycleAvailable
            ? (workRow.canonicalFlock?.nodes ?? []).map {
                Child(workIdentity: workIdentity, node: $0)
            }
            : []
        isAvailable = workRow.isAvailable
        unknownEventRefs = workRow.unknownEventRefs
        unknownDomains = workRow.unknownDomains
        if !workRow.isAvailable {
            unavailableReason = workRow.corruptionReasons.first ?? "Work projection unavailable"
        } else if unknownChildDomain {
            unavailableReason = "Work contains unknown domains; child lifecycle is partial"
        } else if workRow.canonicalFlock?.isAvailable == false {
            unavailableReason = workRow.canonicalFlock?.unavailableReason
                ?? "Child lifecycle read is not an exact canonical Work tip"
        } else {
            unavailableReason = nil
        }
    }

    /// Census has reducer output but no filesystem WorkRow. Keep it on this same production
    /// projection path so fixture reports cannot silently drift from Flock's unknown-domain
    /// suppression rules.
    public static func project(
        sessions: [CanonicalSessionCatalogSummary],
        flock: CanonicalFlockProjection,
        unknownDomains: [TimelineDomain] = []
    ) -> CanonicalFlockCatalogProjection {
        let workIdentity = flock.work.map(Self.qualifiedWork) ?? "unavailable-flock"
        let links = sessions.filter { summary in
            summary.work.contains { $0.isAttached && $0.work == flock.work }
        }.map(SessionLink.init)
        let sessionLinks = Dictionary(grouping: links, by: \.id).compactMap { $0.value.first }
            .sorted { $0.id < $1.id }
        let unknownChildDomain = unknownDomains.contains(.work)
            || unknownDomains.contains(.externalEffects)
            || unknownDomains.contains(.runtime)
        let childAvailable = flock.isAvailable && !unknownChildDomain
        return Self(
            id: workIdentity, locatorID: nil, work: flock.work, journal: flock.journal,
            workHost: flock.workHost, cursor: flock.cursor, lifecycle: nil, execution: nil,
            modelID: nil, sessions: sessionLinks,
            children: childAvailable ? flock.nodes.map { Child(workIdentity: workIdentity, node: $0) } : [],
            isAvailable: flock.isAvailable, childLifecycleAvailable: childAvailable,
            unknownEventRefs: flock.unknownEventRefs, unknownDomains: unknownDomains,
            unavailableReason: !flock.isAvailable ? (flock.unavailableReason ?? "Work projection unavailable")
                : unknownChildDomain ? "Work contains unknown domains; child lifecycle is partial"
                : flock.unavailableReason)
    }

    /// Build deterministic one-row-per-Work data for Flock. Duplicate Work identities remain
    /// separate rows with a presentation suffix rather than selecting an arbitrary authority.
    public static func project(
        sessions: [CanonicalSessionCatalogSummary],
        works: [LocalTimelineCatalog.WorkRow]
    ) -> [CanonicalFlockCatalogProjection] {
        var seen: [String: Int] = [:]
        return works.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if (lhs.locatorID ?? "") != (rhs.locatorID ?? "") {
                return (lhs.locatorID ?? "") < (rhs.locatorID ?? "")
            }
            return (lhs.journal?.stableKey ?? "") < (rhs.journal?.stableKey ?? "")
        }.map { row in
            let base = row.work.map(Self.qualifiedWork) ?? row.id
            let ordinal = seen[base, default: 0]
            seen[base] = ordinal + 1
            let projection = Self(workRow: row, sessions: sessions)
            guard ordinal > 0 else { return projection }
            let locator = row.locatorID ?? "ordinal-\(ordinal + 1)"
            return projection.withPresentationID("\(base)#\(locator)")
        }
    }

    private func withPresentationID(_ value: String) -> Self {
        return Self(
            id: value, locatorID: locatorID, work: work, journal: journal, workHost: workHost, cursor: cursor,
            lifecycle: lifecycle, execution: execution, modelID: modelID, sessions: sessions,
            children: children, isAvailable: isAvailable,
            childLifecycleAvailable: childLifecycleAvailable,
            unknownEventRefs: unknownEventRefs, unknownDomains: unknownDomains,
            unavailableReason: unavailableReason)
    }

    private init(id: String, locatorID: String?, work: WorkRef?, journal: JournalRef?, workHost: WorkHostRef?,
                 cursor: JournalCursor?, lifecycle: WorkLifecycle?, execution: WorkExecution?,
                 modelID: String?, sessions: [SessionLink], children: [Child], isAvailable: Bool,
                 childLifecycleAvailable: Bool, unknownEventRefs: [EventRef],
                 unknownDomains: [TimelineDomain], unavailableReason: String?) {
        self.id = id
        self.locatorID = locatorID
        self.work = work
        self.journal = journal
        self.workHost = workHost
        self.cursor = cursor
        self.lifecycle = lifecycle
        self.execution = execution
        self.modelID = modelID
        self.sessions = sessions
        self.children = children
        self.isAvailable = isAvailable
        self.childLifecycleAvailable = childLifecycleAvailable
        self.unknownEventRefs = unknownEventRefs
        self.unknownDomains = unknownDomains
        self.unavailableReason = unavailableReason
    }

    private static func qualifiedWork(_ work: WorkRef) -> String {
        "work:\(work.workHostID.utf8.count):\(work.workHostID)"
            + ":\(work.workID.utf8.count):\(work.workID)"
    }
}
