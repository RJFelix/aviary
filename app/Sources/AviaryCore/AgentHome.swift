import Foundation

/// Every path Aviary reads or writes under the harness's state directory.
///
/// One place, because the layout is load-bearing and undocumented in parts: sessions are
/// flat JSONL files, child (RLM) sessions hide under `session-artifacts/<parent>/sub-*/`,
/// and the daemon's liveness truth is split between `$TMPDIR` sockets and
/// `daemon-workers/` descriptors.
public struct AgentHome: Sendable, Hashable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/.prime/agent` — the default for a stock `prime-agent` install.
    public static var `default`: AgentHome {
        AgentHome(root: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".prime/agent", directoryHint: .isDirectory))
    }

    public var sessionsDir: URL { root.appending(path: "sessions", directoryHint: .isDirectory) }
    public var artifactsDir: URL { root.appending(path: "session-artifacts", directoryHint: .isDirectory) }
    public var rlmLedgerDir: URL { root.appending(path: "rlm-ledger", directoryHint: .isDirectory) }
    public var workersDir: URL { root.appending(path: "daemon-workers", directoryHint: .isDirectory) }
    public var leasesDir: URL { root.appending(path: "session-leases", directoryHint: .isDirectory) }
    public var logsDir: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    public var kernelVenv: URL { root.appending(path: "kernel-venv", directoryHint: .isDirectory) }

    public var modelsFile: URL { root.appending(path: "models.json") }
    public var settingsFile: URL { root.appending(path: "settings.json") }
    public var authFile: URL { root.appending(path: "auth.json") }
    public var agentsFile: URL { root.appending(path: "AGENTS.md") }
    public var agentLog: URL { logsDir.appending(path: "agent.jsonl") }

    public var promptsDir: URL { root.appending(path: "prompts", directoryHint: .isDirectory) }
    public var skillsDir: URL { root.appending(path: "skills", directoryHint: .isDirectory) }
    public var extensionsDir: URL { root.appending(path: "extensions", directoryHint: .isDirectory) }
    public var agentProfilesDir: URL { root.appending(path: "agents", directoryHint: .isDirectory) }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    /// `$TMPDIR/prime-agent-<uid>` — where the supervisor and worker sockets live.
    ///
    /// Deliberately derived rather than read from a config file: the harness computes it the
    /// same way, and a stale descriptor pointing at a previous boot's TMPDIR is exactly the
    /// kind of thing that makes a daemon look alive when it isn't.
    public static var socketDir: URL {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let uid = getuid()
        return URL(fileURLWithPath: tmp, isDirectory: true)
            .appending(path: "prime-agent-\(uid)", directoryHint: .isDirectory)
    }

    public static var supervisorSocket: URL { socketDir.appending(path: "daemon.sock") }

    public static var supervisorOwnersDir: URL {
        socketDir.appending(path: "supervisor-owners", directoryHint: .isDirectory)
    }

    public func sessionFile(id: String) -> URL {
        sessionsDir.appending(path: "\(id).jsonl")
    }

    public func artifacts(forSession id: String) -> URL {
        artifactsDir.appending(path: id, directoryHint: .isDirectory)
    }

    public func scheduledJobs(forSession id: String) -> URL {
        artifacts(forSession: id).appending(path: "scheduled-jobs.json")
    }
}

/// Where the execution engine lives, and how sure we are about it.
public struct EngineLocation: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// Aviary's own forked harness, built from `harness/`.
        case fork
        /// A `prime-agent` found on PATH or in a known install root.
        case installed
        /// A path the user set explicitly.
        case custom

        public var label: String {
            switch self {
            case .fork: return "Bundled fork"
            case .installed: return "Installed prime-agent"
            case .custom: return "Custom path"
            }
        }
    }

    public var id: String { path }
    public let kind: Kind
    /// Executable to launch. For the fork this is `node`; the CLI is passed as an argument.
    public let path: String
    public let leadingArguments: [String]
    public let version: String?
    /// Human-readable note about how it was found, shown in Health.
    public let note: String

    public init(kind: Kind, path: String, leadingArguments: [String] = [], version: String? = nil, note: String = "") {
        self.kind = kind
        self.path = path
        self.leadingArguments = leadingArguments
        self.version = version
        self.note = note
    }

    public var displayPath: String {
        leadingArguments.isEmpty ? path : ([path] + leadingArguments).joined(separator: " ")
    }
}

/// Finds a runnable engine.
///
/// Order matters: Aviary's own fork wins when it has been built, because that is the copy
/// you can edit. Otherwise fall back to whatever `prime-agent` is installed, resolved
/// through the login shell — the global install lives under an asdf Node directory that a
/// GUI process's inherited PATH does not contain.
public enum EngineLocator {
    /// Candidate locations for the fork's built CLI, relative to the repo root.
    static let forkCLIRelative = "harness/packages/coding-agent/dist/bundle/cli.js"

    /// Walk up from a starting directory looking for the Aviary repo root.
    public static func repoRoot(startingAt start: URL = URL(fileURLWithPath: Bundle.main.bundlePath)) -> URL? {
        var dir = start
        for _ in 0..<12 {
            let marker = dir.appending(path: "harness/packages/coding-agent/package.json")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // Development fallback: the conventional checkout location.
        let conventional = FileManager.default.homeDirectoryForCurrentUser.appending(path: "duckbill/aviary")
        if FileManager.default.fileExists(
            atPath: conventional.appending(path: forkCLIRelative).path) { return conventional }
        return nil
    }

    public static func discover(customPath: String? = nil) async -> [EngineLocation] {
        var found: [EngineLocation] = []

        if let customPath, !customPath.isEmpty {
            let v = await version(of: customPath, args: [])
            found.append(EngineLocation(
                kind: .custom, path: customPath, version: v,
                note: "Set in Aviary settings"))
        }

        if let root = repoRoot() {
            let cli = root.appending(path: forkCLIRelative)
            if FileManager.default.fileExists(atPath: cli.path),
               let node = await Shell.which("node")
            {
                // Prefer the declared version: launching the bundled CLI just to ask costs
                // seconds and occasionally returns nothing at all, and the manifest next to
                // it already knows the answer.
                let declared = declaredVersion(
                    packageJSON: root.appending(path: "harness/packages/coding-agent/package.json"))
                var v = declared
                if v == nil { v = await version(of: node, args: [cli.path]) }
                found.append(EngineLocation(
                    kind: .fork, path: node, leadingArguments: [cli.path], version: v,
                    note: "Built from \(root.appending(path: "harness").path)"))
            }
        }

        if let installed = await Shell.which("prime-agent") {
            let v = await version(of: installed, args: [])
            found.append(EngineLocation(
                kind: .installed, path: installed, version: v,
                note: "Resolved through your login shell"))
        }

        return found
    }

    /// `version` from a package manifest, if it parses.
    static func declaredVersion(packageJSON: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: packageJSON.path),
              let v = JSONValue.parse(data),
              let version = v["version"]?.stringValue,
              !version.isEmpty
        else { return nil }
        return version
    }

    static func version(of executable: String, args: [String]) async -> String? {
        guard case .success(let r) = await Shell.run(
            executable, args + ["--version"], timeout: 45), r.ok else { return nil }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
