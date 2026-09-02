import Foundation

/// One spawned sub-agent (an "RLM child") and everything the harness recorded about it.
public struct AgentNode: Sendable, Identifiable, Hashable {
    public var id: String            // childId, e.g. "sub-4a1242a5"
    public var name: String
    public var sessionID: String
    public var sessionFile: URL
    public var sessionDir: URL
    public var parentSessionID: String
    public var depth: Int
    public var maxDepth: Int
    public var status: String        // running | completed | failed | archived | …
    public var provider: String?
    public var model: String?
    public var prompt: String
    /// The Python that spawned it — often spawns several siblings in one call, which is
    /// the single most useful thing to see when reading a fan-out after the fact.
    public var spawnCode: String
    public var createdAt: Date
    public var updatedAt: Date
    public var children: [AgentNode] = []

    public var isRunning: Bool { status == "running" || status == "active" }
    public var isFailed: Bool { status == "failed" || status == "error" }
    public var isComplete: Bool {
        status == "completed" || status == "done" || status == "canceled"
    }

    public var duration: TimeInterval { max(0, updatedAt.timeIntervalSince(createdAt)) }

    public var modelLabel: String {
        switch (provider, model) {
        case (let p?, let m?): return "\(p)/\(m)"
        case (nil, let m?): return m
        case (let p?, nil): return p
        default: return "—"
        }
    }

    /// Nodes in this subtree including self, depth-first.
    public var flattened: [AgentNode] {
        [self] + children.flatMap(\.flattened)
    }
}

public struct AgentTree: Sendable {
    public init() {}

    /// Roots keyed by the top-level session that owns them.
    public var byParentSession: [String: [AgentNode]] = [:]
    /// Flat parent→child edges, cheap for counting.
    public var edges: [(parentSessionID: String, childID: String)] = []
    public var allNodes: [AgentNode] = []

    public func roots(forSession id: String) -> [AgentNode] {
        byParentSession[id] ?? []
    }

    public var runningCount: Int { allNodes.filter(\.isRunning).count }
}

/// The bounded canonical projection that Flock can consume while the richer legacy tree is
/// still backed by `rlm-subagents.jsonl`.  A canonical child row deliberately contains only
/// facts present on the Work journal: it has no fabricated transcript URL, model, attention, or
/// session identity.  Those are separate Session/Work projections and must not be inferred from
/// a child id or from an unaligned read.
public struct CanonicalFlockNode: Codable, Hashable, Sendable, Identifiable {
    public let childID: String
    public let name: String?
    public let state: String
    public let parentSession: SessionRef?
    public let parentWork: WorkRef
    public let parentRun: RunRef?
    public let source: EventRef

    public var id: String { childID }

    public init(childID: String, name: String?, state: String,
                parentSession: SessionRef?, parentWork: WorkRef,
                parentRun: RunRef?, source: EventRef) {
        self.childID = childID
        self.name = name
        self.state = state
        self.parentSession = parentSession
        self.parentWork = parentWork
        self.parentRun = parentRun
        self.source = source
    }
}

/// A source-qualified, exact-tip projection for the Flock reader.
public struct CanonicalFlockProjection: Codable, Hashable, Sendable {
    /// Identity is nil when the supplied snapshot cannot establish a canonical Work owner;
    /// unavailable output must not manufacture an "unknown" host or journal.
    public let journal: JournalRef?
    public let work: WorkRef?
    public let workHost: WorkHostRef?
    public let cursor: JournalCursor?
    public let nodes: [CanonicalFlockNode]
    public let isAvailable: Bool
    public let integrityValid: Bool
    public let unknownEventRefs: [EventRef]
    public let unavailableReason: String?

    public init(journal: JournalRef?, work: WorkRef?, workHost: WorkHostRef?,
                cursor: JournalCursor?, nodes: [CanonicalFlockNode], isAvailable: Bool,
                integrityValid: Bool, unknownEventRefs: [EventRef] = [],
                unavailableReason: String? = nil) {
        self.journal = journal
        self.work = work
        self.workHost = workHost
        self.cursor = cursor
        self.nodes = nodes
        self.isAvailable = isAvailable
        self.integrityValid = integrityValid
        self.unknownEventRefs = unknownEventRefs
        self.unavailableReason = unavailableReason
    }
}

/// Reads the sub-agent topology out of the harness's own bookkeeping.
///
/// Two sources record it and they disagree in useful ways: `rlm-ledger/*.jsonl` is an
/// append-only spawn log (complete, but spawn-time only), while each parent's
/// `session-artifacts/<id>/rlm-subagents.jsonl` carries live status, model, and the prompt
/// text. Aviary reads the per-session files as primary — they are the ones that get
/// updated — and folds in ledger edges the artifacts missed.
public enum AgentTreeReader {
    private struct LegacyNodeKey: Hashable {
        let parentSessionID: String
        let childID: String
    }

    /// Project child lifecycle records for Flock only when the supplied Work read is an exact,
    /// canonical append-chain ending at the supplied reducer snapshot. Stale, divergent,
    /// foreign, tailed, or corrupt reads are visible as unavailable and yield no child rows;
    /// this prevents Flock from turning a partial host view into a false lifecycle.
    public static func canonicalProjection(
        work: WorkSnapshot, read: TimelineJournalReadResult
    ) -> CanonicalFlockProjection {
        guard let journal = work.journal, let workRef = work.work,
              let host = work.workHost,
              case .work(let journalWork) = journal.owner,
              journalWork == workRef,
              journal.authority.authorityID == host.workHostID,
              host == WorkHostRef(workRef.workHostID),
              read.records.isEmpty == false,
              read.quarantinedSuffix == nil, read.truncatedTail == nil,
              read.records.allSatisfy({
                  $0.event.journal == journal
                      && ($0.event.work == nil || $0.event.work == workRef)
                      && ($0.event.workHost == nil || $0.event.workHost == host)
              }),
              read.records.first?.event.sequence == 1,
              read.records.first?.event.previousEventID == nil,
              read.records.dropFirst().enumerated().allSatisfy({ offset, record in
                  let previous = read.records[offset].event
                  return record.event.sequence == previous.sequence + 1
                      && record.event.previousEventID == previous.eventID
              }),
              Set(read.records.map { $0.event.eventID }).count == read.records.count,
              let last = read.records.last,
              work.lastEventID == last.event.eventID,
              work.lastSequence == last.event.sequence,
              work.structuralIntegrityValid, work.semanticProjectionValid
        else {
            return CanonicalFlockProjection(
                journal: work.journal, work: work.work,
                workHost: work.workHost,
                cursor: nil, nodes: [], isAvailable: false, integrityValid: false,
                unavailableReason: "Work read is not an exact canonical reducer tip")
        }

        var latest: [String: CanonicalFlockNode] = [:]
        for event in read.records.map(\.event) where event.type == TimelineEventType.childLifecycle {
            guard let childID = event.payload["child_id"]?.stringValue,
                  let state = event.payload["state"]?.stringValue,
                  !childID.isEmpty, !state.isEmpty,
                  let eventWork = event.work, eventWork == workRef,
                  (event.payload["parent_session_id"]?.stringValue == nil
                      || event.payload["parent_session_id"]?.stringValue == event.session?.sessionID),
                  (event.payload["parent_run_id"]?.stringValue == nil
                      || event.payload["parent_run_id"]?.stringValue == event.run?.runID)
        else { continue }
            latest[childID] = CanonicalFlockNode(
                childID: childID, name: event.payload["name"]?.stringValue, state: state,
                parentSession: event.session, parentWork: workRef,
                parentRun: event.run,
                source: EventRef(journal: journal, eventID: event.eventID))
        }
        let cursor = JournalCursor(journal: journal, eventID: last.event.eventID,
                                   sequence: last.event.sequence)
        return CanonicalFlockProjection(
            journal: journal, work: workRef, workHost: host, cursor: cursor,
            nodes: latest.values.sorted { $0.childID < $1.childID },
            isAvailable: true, integrityValid: true,
            unknownEventRefs: work.unknownEvents.map {
                EventRef(journal: $0.event.journal, eventID: $0.event.eventID)
            })
    }

    public static func read(home: AgentHome) -> AgentTree {
        // childId is only unique inside one parent Session. Keep the parent in the reader key;
        // AgentNode.id remains the legacy childId compatibility field for callers.
        var nodes: [LegacyNodeKey: AgentNode] = [:]
        var tree = AgentTree()

        // 1. Per-session sub-agent records (recursive: grandchildren nest their own
        // session-artifacts dir inside the parent's).
        let fm = FileManager.default
        if let walker = fm.enumerator(
            at: home.artifactsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            for case let url as URL in walker {
                guard url.lastPathComponent == "rlm-subagents.jsonl" else { continue }
                guard let data = fm.contents(atPath: url.path) else { continue }
                for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    guard let v = JSONValue.parse(Data(chunk)),
                          v["type"]?.stringValue == "rlm_subagent",
                          let childID = v["childId"]?.stringValue,
                          let sessionFile = v["sessionFile"]?.stringValue,
                          let parentSessionID = v["parentSessionId"]?.stringValue
                    else { continue }

                    let sessionURL = URL(fileURLWithPath: sessionFile)
                    let childSessionID = sessionURL.deletingPathExtension().lastPathComponent
                    let node = AgentNode(
                        id: childID,
                        name: v["sessionName"]?.stringValue ?? childID,
                        sessionID: childSessionID,
                        sessionFile: sessionURL,
                        sessionDir: URL(fileURLWithPath:
                            v["sessionDir"]?.stringValue ?? sessionURL.deletingLastPathComponent().path,
                            isDirectory: true),
                        parentSessionID: parentSessionID,
                        depth: v["rlmDepth"]?.intValue ?? 1,
                        maxDepth: v["rlmMaxDepth"]?.intValue ?? 1,
                        status: v["status"]?.stringValue ?? "unknown",
                        provider: v.path("model.provider")?.stringValue,
                        model: v.path("model.modelId")?.stringValue,
                        prompt: v["prompt"]?.stringValue ?? "",
                        spawnCode: v["spawnCode"]?.stringValue ?? "",
                        createdAt: epochOrISO(v["createdAt"]),
                        updatedAt: epochOrISO(v["updatedAt"]))

                    // Later records supersede earlier ones for the same parent-qualified child.
                    let key = LegacyNodeKey(parentSessionID: parentSessionID, childID: childID)
                    if let existing = nodes[key], existing.updatedAt > node.updatedAt { continue }
                    nodes[key] = node
                }
            }
        }

        // 2. Ledger fill-in for spawns with no artifact record yet (a child that died
        // before its first status write still deserves to appear).
        if let ledgerFiles = try? fm.contentsOfDirectory(
            at: home.rlmLedgerDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
            for file in ledgerFiles where file.pathExtension == "jsonl" {
                guard let data = fm.contents(atPath: file.path) else { continue }
                for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    guard let v = JSONValue.parse(Data(chunk)),
                          v["op"]?.stringValue == "spawn",
                          let childID = v["childId"]?.stringValue,
                          let childPath = v["child"]?.stringValue,
                          let parentPath = v["parent"]?.stringValue
                    else { continue }
                    let childURL = URL(fileURLWithPath: childPath)
                    let parentID = URL(fileURLWithPath: parentPath)
                        .deletingPathExtension().lastPathComponent
                    let childSessionID = childURL.deletingPathExtension().lastPathComponent
                    let key = LegacyNodeKey(parentSessionID: parentID, childID: childID)
                    guard nodes[key] == nil else { continue }
                    nodes[key] = AgentNode(
                        id: childID,
                        name: v["name"]?.stringValue ?? childID,
                        sessionID: childSessionID,
                        sessionFile: childURL,
                        sessionDir: childURL.deletingLastPathComponent(),
                        parentSessionID: parentID,
                        depth: v["depth"]?.intValue ?? 1,
                        maxDepth: v["depth"]?.intValue ?? 1,
                        status: "unknown",
                        provider: nil, model: nil, prompt: "", spawnCode: "",
                        createdAt: ISO8601.date(v["at"]?.stringValue) ?? .distantPast,
                        updatedAt: ISO8601.date(v["at"]?.stringValue) ?? .distantPast)
                }
            }
        }

        // 3. Build the tree. A node's parent is either another sub-agent (when its
        // parentSessionID is itself a child session) or a top-level session.
        var childrenOf: [LegacyNodeKey: [LegacyNodeKey]] = [:]
        var topLevel: [String: [LegacyNodeKey]] = [:]
        let nodeKeysBySessionID = Dictionary(grouping: nodes.keys) { key in
            nodes[key]!.sessionID
        }

        for (key, node) in nodes {
            // A child session id can collide across authorities/parents. Only a unique match
            // is safe to nest; ambiguity stays visible as a top-level/unknown root.
            if let parentKeys = nodeKeysBySessionID[node.parentSessionID], parentKeys.count == 1,
               let parentKey = parentKeys.first {
                childrenOf[parentKey, default: []].append(key)
            } else {
                topLevel[node.parentSessionID, default: []].append(key)
            }
            tree.edges.append((parentSessionID: node.parentSessionID, childID: node.id))
        }

        func attach(_ key: LegacyNodeKey, guardDepth: Int = 0) -> AgentNode {
            guard let node = nodes[key] else {
                fatalError("AgentTree reader lost qualified node")
            }
            var n = node
            guard guardDepth < 12 else { return n }  // cycle guard
            n.children = (childrenOf[key] ?? [])
                .sorted { lhs, rhs in
                    let left = nodes[lhs]!, right = nodes[rhs]!
                    if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
                    return lhs.childID < rhs.childID
                }
                .map { attach($0, guardDepth: guardDepth + 1) }
            return n
        }

        for sessionID in topLevel.keys.sorted() {
            let kids = topLevel[sessionID] ?? []
            tree.byParentSession[sessionID] = kids
                .sorted { lhs, rhs in
                    let left = nodes[lhs]!, right = nodes[rhs]!
                    if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
                    return lhs.childID < rhs.childID
                }
                .map { attach($0) }
        }
        tree.allNodes = tree.byParentSession.values.flatMap { $0.flatMap(\.flattened) }
        return tree
    }

    /// `createdAt` is epoch-ms; `updatedAt` is ISO-8601. Both appear in the same record.
    static func epochOrISO(_ v: JSONValue?) -> Date {
        if let s = v?.stringValue, let d = ISO8601.date(s) { return d }
        if let n = v?.doubleValue, n > 0 {
            return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        }
        return .distantPast
    }
}

/// The IPython kernel's saved namespace for a session.
///
/// The harness's only tool is a Python kernel, so this list of variable names *is* the
/// agent's working memory. Being able to see it is the difference between "the agent did
/// some stuff" and "the agent is holding 63 named intermediate results".
public struct KernelState: Sendable {
    public var savedNames: [String]
    public var version: Int
    public var stateFileSize: Int
    public var savedAt: Date?

    public static func read(home: AgentHome, sessionID: String) -> KernelState? {
        let dir = home.artifacts(forSession: sessionID)
        let jsonURL = dir.appending(path: "kernel-state.json")
        guard let data = FileManager.default.contents(atPath: jsonURL.path),
              let v = JSONValue.parse(data) else { return nil }
        let dill = dir.appending(path: "kernel-state.dill")
        let attrs = try? dill.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return KernelState(
            savedNames: (v["savedNames"]?.arrayValue ?? []).compactMap(\.stringValue),
            version: v["version"]?.intValue ?? 1,
            stateFileSize: attrs?.fileSize ?? 0,
            savedAt: attrs?.contentModificationDate)
    }
}
