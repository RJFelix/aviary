import Foundation

// MARK: - Live sessions

/// A session the daemon currently holds in a worker.
///
/// This is the only view of *now*: the transcript on disk tells you what happened, but
/// whether a session is streaming, what it is waiting on, and which worker owns it lives
/// exclusively in the daemon.
public struct LiveSession: Sendable, Identifiable, Hashable {
    public var id: String                 // active session id (short handle)
    public var sessionID: String          // full session uuid
    public var sessionFile: URL
    public var name: String?
    public var cwd: String
    public var lifecycle: String          // live | archived | …
    public var activity: String           // working | idle | …
    public var isStreaming: Bool
    public var isCompacting: Bool
    public var attachedClients: Int
    public var messageCount: Int
    public var queuedCount: Int
    public var steering: [String]
    public var followUps: [String]
    public var created: Date?
    public var modified: Date?
    public var lastActivityAt: Date?
    public var provider: String?
    public var model: String?
    public var runtimeKind: String?       // subagent | root | …
    public var rlmDepth: Int
    public var rlmChildID: String?
    public var parentSessionID: String?
    public var spawnCode: String?
    public var workerState: String?
    public var workerPID: Int?
    public var firstMessage: String?

    public var isWorking: Bool { activity == "working" || isStreaming }
    public var isSubagent: Bool { runtimeKind == "subagent" || rlmDepth > 0 }

    public var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let f = firstMessage, f != "(no messages)", !f.isEmpty {
            return SessionCatalog.condense(f, limit: 80)
        }
        return id
    }

    public var modelLabel: String? {
        switch (provider, model) {
        case (let p?, let m?): return "\(p)/\(m)"
        case (nil, let m?): return m
        default: return nil
        }
    }

    init?(json v: JSONValue) {
        guard let id = v["id"]?.stringValue,
              let file = v["sessionFile"]?.stringValue else { return nil }
        self.id = id
        sessionID = v["sessionId"]?.stringValue
            ?? URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        sessionFile = URL(fileURLWithPath: file)
        name = v["sessionName"]?.stringValue
        cwd = v["cwd"]?.stringValue ?? ""
        lifecycle = v["lifecycle"]?.stringValue ?? "unknown"
        activity = v["activity"]?.stringValue ?? "unknown"
        isStreaming = v["isStreaming"]?.boolValue ?? false
        isCompacting = v["isCompacting"]?.boolValue ?? false
        attachedClients = v["attachedClients"]?.intValue ?? 0
        messageCount = v["messageCount"]?.intValue ?? 0
        queuedCount = v.path("sessionActions.queuedCount")?.intValue ?? 0
        steering = (v.path("sessionActions.steering")?.arrayValue ?? []).compactMap(\.stringValue)
        followUps = (v.path("sessionActions.followUps")?.arrayValue ?? []).compactMap(\.stringValue)
        created = ISO8601.date(v["created"]?.stringValue)
        modified = ISO8601.date(v["modified"]?.stringValue)
        lastActivityAt = ISO8601.date(v["lastActivityAt"]?.stringValue)
        // `list --json` reports the model as a "provider/id" string or as an object,
        // depending on release. Accept both.
        if let m = v["model"] {
            if let s = m.stringValue {
                let parts = s.split(separator: "/", maxSplits: 1)
                if parts.count == 2 { provider = String(parts[0]); model = String(parts[1]) }
                else { model = s }
            } else {
                provider = m["provider"]?.stringValue
                model = m["modelId"]?.stringValue ?? m["id"]?.stringValue
            }
        }
        runtimeKind = v["runtimeKind"]?.stringValue
        rlmDepth = v["rlmDepth"]?.intValue ?? 0
        rlmChildID = v["rlmChildId"]?.stringValue
        parentSessionID = v["parentSessionId"]?.stringValue
        spawnCode = v["spawnCode"]?.stringValue
        workerState = v["workerState"]?.stringValue
        workerPID = v["workerPid"]?.intValue
        firstMessage = v["firstMessage"]?.stringValue
    }
}

// MARK: - Daemon status

public struct DaemonStatus: Sendable {
    public init() {}

    public enum Health: String, Sendable {
        case healthy
        case notRunning
        /// Answers the handshake but refuses commands — the wedged-supervisor failure.
        case wedged
        /// A supervisor from a different build owns the socket.
        case versionMismatch
        case unknown

        public var label: String {
            switch self {
            case .healthy: return "Healthy"
            case .notRunning: return "Not running"
            case .wedged: return "Wedged"
            case .versionMismatch: return "Version conflict"
            case .unknown: return "Unknown"
            }
        }
    }

    public var health: Health = .unknown
    public var pid: Int?
    public var version: String?
    public var buildID: String?
    public var protocolVersion: Int?
    public var executablePath: String?
    public var sessionCount: Int?
    public var hasTrackedWorkers: Bool = false
    public var socketPath: String = AgentHome.supervisorSocket.path
    public var socketExists: Bool = false
    /// Live IPython kernels, counted from the process table. Each costs real memory, and
    /// leaked ones are invisible in the harness's own output.
    public var kernelPIDs: [Int] = []
    public var workerPIDs: [Int] = []
    public var clientPIDs: [Int] = []
    public var checkedAt: Date = Date()
    /// What went wrong, verbatim, when something did.
    public var diagnostic: String?
    /// The concrete next step, or nil when nothing is wrong.
    public var remedy: String?

    public var isRunning: Bool {
        health == .healthy || health == .wedged || health == .versionMismatch
    }

    public var kernelCount: Int { kernelPIDs.count }
}

/// Worker descriptor written under `daemon-workers/<generation>/`.
public struct WorkerDescriptor: Sendable, Identifiable, Hashable {
    public var id: String            // workerId
    public var generation: String
    public var pid: Int
    public var socketPath: String
    public var lastOperation: String?
    public var lastSessionID: String?
    public var busy: Bool = false
    public var recordedAt: Date?
    public var processAlive: Bool = false
    /// Tracked detached children (bash trees) this worker is responsible for reaping.
    public var orphanPIDs: [Int] = []
}

/// Inspects and repairs the daemon.
///
/// Deliberately built from three independent signals, because each one lies on its own:
/// `doctor` still completes its handshake against a supervisor that refuses every real
/// command; `ps aux | grep` has been observed returning nothing while `pgrep -fl` finds
/// every process; and a socket file outliving its owner looks exactly like a running
/// daemon. Aviary cross-checks them and names which one disagreed.
public actor DaemonInspector {
    private let home: AgentHome
    private var engine: EngineLocation?

    public init(home: AgentHome, engine: EngineLocation?) {
        self.home = home
        self.engine = engine
    }

    public func setEngine(_ e: EngineLocation?) { engine = e }

    // MARK: Status

    public func status() async -> DaemonStatus {
        var s = DaemonStatus()
        s.socketExists = FileManager.default.fileExists(atPath: s.socketPath)

        let processes = await Self.primeProcesses()
        s.kernelPIDs = processes.filter { $0.isKernel }.map(\.pid)
        s.clientPIDs = processes.filter { !$0.isKernel }.map(\.pid)

        guard let engine else {
            s.health = s.socketExists ? .unknown : .notRunning
            s.diagnostic = "No prime-agent engine configured."
            s.remedy = "Pick an engine in Settings, or build the bundled fork with `just build-engine`."
            return s
        }

        // 1. Handshake.
        let doctor = await Shell.run(
            engine.path, engine.leadingArguments + ["doctor", "--json"], timeout: 30)
        var handshakeOK = false
        if case .success(let r) = doctor, r.ok,
           let v = JSONValue.parse(Data(r.stdout.utf8)),
           let first = v.arrayValue?.first ?? (v.objectValue != nil ? v : nil)
        {
            handshakeOK = true
            s.pid = first["pid"]?.intValue
            s.version = first["version"]?.stringValue
            s.buildID = first["buildId"]?.stringValue
            s.protocolVersion = first["protocolVersion"]?.intValue
            s.executablePath = first["executablePath"]?.stringValue
            s.sessionCount = first["sessionCount"]?.intValue
            s.hasTrackedWorkers = first["hasTrackedWorkers"]?.boolValue ?? false
            s.socketPath = first["socketPath"]?.stringValue ?? s.socketPath
        }

        if !handshakeOK {
            s.health = .notRunning
            s.diagnostic = s.socketExists
                ? "A socket exists at \(s.socketPath) but nothing answered the handshake."
                : "No supervisor socket. Nothing is running."
            s.remedy = s.socketExists
                ? "Stale socket — the next session start clears it. `Repair` runs doctor --fix."
                : "Start a session; the supervisor launches on demand."
            return s
        }

        // 2. Ownership assertion. `list` is the cheapest command that goes through the
        // supervisor's ownership check, which is exactly what a wedged daemon fails.
        let list = await Shell.run(
            engine.path, engine.leadingArguments + ["list", "--json"], timeout: 30)
        switch list {
        case .success(let r) where r.ok:
            s.health = .healthy
        case .success(let r):
            let text = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("no longer owns its registry entry") {
                s.health = .wedged
                s.diagnostic = "The supervisor (pid \(s.pid.map(String.init) ?? "?")) still holds "
                    + "its socket but lost its ownership lease, so it rejects every command. "
                    + "It cannot self-heal: nothing new can start while the socket is held."
                s.remedy = "Force-shutdown. Nothing is lost — transcripts are on disk and the "
                    + "next launch reaps the poisoned lease."
            } else if text.contains("different Prime Agent version") {
                s.health = .versionMismatch
                s.diagnostic = text
                s.remedy = "Point Aviary at the engine that owns the running daemon, or shut it "
                    + "down once its busy sessions finish."
            } else {
                s.health = .unknown
                s.diagnostic = text.isEmpty ? "`list` failed with no output." : text
                s.remedy = "Check the daemon log in Health → Logs."
            }
        case .failure(let e):
            s.health = .unknown
            s.diagnostic = e.localizedDescription
        }

        return s
    }

    /// Live sessions, straight from the daemon.
    public func liveSessions() async -> [LiveSession] {
        guard let engine else { return [] }
        let r = await Shell.run(
            engine.path, engine.leadingArguments + ["list", "--json"], timeout: 30)
        guard case .success(let res) = r, res.ok,
              let v = JSONValue.parse(Data(res.stdout.utf8)),
              let arr = v["sessions"]?.arrayValue ?? v.arrayValue
        else { return [] }
        return arr.compactMap(LiveSession.init(json:))
    }

    /// Worker descriptors from disk. Works when the daemon does not answer, which is when
    /// you most want to know what it left behind.
    public func workers() -> [WorkerDescriptor] {
        let fm = FileManager.default
        guard let generations = try? fm.contentsOfDirectory(
            at: home.workersDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }

        var out: [WorkerDescriptor] = []
        for gen in generations {
            guard let files = try? fm.contentsOfDirectory(
                at: gen, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for f in files where f.pathExtension == "json" {
                guard let data = fm.contents(atPath: f.path), let v = JSONValue.parse(data),
                      let id = v["workerId"]?.stringValue, let pid = v["pid"]?.intValue
                else { continue }
                var w = WorkerDescriptor(
                    id: id,
                    generation: gen.lastPathComponent,
                    pid: pid,
                    socketPath: v["socketPath"]?.stringValue ?? "")
                w.processAlive = Self.isAlive(pid: pid)

                // Latest line of the recovery journal is this worker's last known state.
                let journal = gen.appending(path: "\(id).recovery.jsonl")
                if let jdata = fm.contents(atPath: journal.path),
                   let last = jdata.split(separator: UInt8(ascii: "\n"),
                                          omittingEmptySubsequences: true).last,
                   let jv = JSONValue.parse(Data(last))
                {
                    w.lastOperation = jv["operation"]?.stringValue
                    w.lastSessionID = jv["sessionId"]?.stringValue
                    w.busy = jv["busy"]?.boolValue ?? false
                    w.recordedAt = ISO8601.date(jv["recordedAt"]?.stringValue)
                }

                let orphans = gen.appending(path: "\(id).orphans.jsonl")
                if let odata = fm.contents(atPath: orphans.path) {
                    var active = Set<Int>()
                    for chunk in odata.split(separator: UInt8(ascii: "\n"),
                                             omittingEmptySubsequences: true) {
                        guard let ov = JSONValue.parse(Data(chunk)),
                              let p = ov["pid"]?.intValue else { continue }
                        if ov["active"]?.boolValue == true { active.insert(p) } else { active.remove(p) }
                    }
                    w.orphanPIDs = active.filter { Self.isAlive(pid: $0) }.sorted()
                }
                out.append(w)
            }
        }
        return out.sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
    }

    // MARK: Repair

    public func shutdown(force: Bool) async -> ProcessResult? {
        guard let engine else { return nil }
        var args = engine.leadingArguments + ["shutdown"]
        if force { args.append("--force") }
        guard case .success(let r) = await Shell.run(engine.path, args, timeout: 90) else { return nil }
        return r
    }

    /// `doctor --fix`. Clears stale sockets and idle orphans only — it deliberately skips
    /// a wedged-but-live supervisor, which reports itself as current.
    public func repair() async -> ProcessResult? {
        guard let engine else { return nil }
        guard case .success(let r) = await Shell.run(
            engine.path, engine.leadingArguments + ["doctor", "--fix"], timeout: 90) else { return nil }
        return r
    }

    // MARK: Process table

    struct PrimeProcess: Sendable {
        let pid: Int
        let command: String
        var isKernel: Bool { command.contains("ipykernel_launcher") }
    }

    /// `pgrep -fl`, not `ps aux | grep`. The latter has been observed returning nothing
    /// while four prime-agent processes were running — a wrong "no daemon" answer that
    /// sends diagnosis down the wrong path entirely.
    static func primeProcesses() async -> [PrimeProcess] {
        let out = await Shell.capture("/usr/bin/pgrep", ["-fl", "prime-agent"], timeout: 10)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let pidStr = parts.first, let pid = Int(pidStr) else { return nil }
            return PrimeProcess(pid: pid, command: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    static func isAlive(pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
