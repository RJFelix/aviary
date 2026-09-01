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

/// Reads the sub-agent topology out of the harness's own bookkeeping.
///
/// Two sources record it and they disagree in useful ways: `rlm-ledger/*.jsonl` is an
/// append-only spawn log (complete, but spawn-time only), while each parent's
/// `session-artifacts/<id>/rlm-subagents.jsonl` carries live status, model, and the prompt
/// text. Aviary reads the per-session files as primary — they are the ones that get
/// updated — and folds in ledger edges the artifacts missed.
public enum AgentTreeReader {
    public static func read(home: AgentHome) -> AgentTree {
        var nodes: [String: AgentNode] = [:]         // childId -> node
        var childSessionToParent: [String: String] = [:]  // child session id -> parent session id
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

                    // Later records supersede earlier ones for the same child.
                    if let existing = nodes[childID], existing.updatedAt > node.updatedAt { continue }
                    nodes[childID] = node
                    childSessionToParent[childSessionID] = parentSessionID
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
                          nodes[childID] == nil,
                          let childPath = v["child"]?.stringValue,
                          let parentPath = v["parent"]?.stringValue
                    else { continue }
                    let childURL = URL(fileURLWithPath: childPath)
                    let parentID = URL(fileURLWithPath: parentPath)
                        .deletingPathExtension().lastPathComponent
                    let childSessionID = childURL.deletingPathExtension().lastPathComponent
                    nodes[childID] = AgentNode(
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
                    childSessionToParent[childSessionID] = parentID
                }
            }
        }

        // 3. Build the tree. A node's parent is either another sub-agent (when its
        // parentSessionID is itself a child session) or a top-level session.
        var childrenOf: [String: [AgentNode]] = [:]  // parent childId -> children
        var topLevel: [String: [AgentNode]] = [:]    // root session id -> children
        let nodeBySessionID = Dictionary(nodes.values.map { ($0.sessionID, $0) },
                                        uniquingKeysWith: { a, _ in a })

        for node in nodes.values {
            if let parentNode = nodeBySessionID[node.parentSessionID] {
                childrenOf[parentNode.id, default: []].append(node)
            } else {
                topLevel[node.parentSessionID, default: []].append(node)
            }
            tree.edges.append((parentSessionID: node.parentSessionID, childID: node.id))
        }

        func attach(_ node: AgentNode, guardDepth: Int = 0) -> AgentNode {
            var n = node
            guard guardDepth < 12 else { return n }  // cycle guard
            n.children = (childrenOf[node.id] ?? [])
                .sorted { $0.createdAt < $1.createdAt }
                .map { attach($0, guardDepth: guardDepth + 1) }
            return n
        }

        for (sessionID, kids) in topLevel {
            tree.byParentSession[sessionID] = kids
                .sorted { $0.createdAt < $1.createdAt }
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
