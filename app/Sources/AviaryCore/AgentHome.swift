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

    /// `~/.aviary` — Aviary's own data directory.
    ///
    /// It was `~/.prime/agent` while Aviary ran on a fork of Prime Agent and shared its
    /// store. Flat rather than `~/.aviary/agent`: the nested level existed because the agent
    /// was one of several things a `prime-agent` install kept, and there is no second thing
    /// here.
    ///
    /// The move was a copy, not a rename — `~/.prime` is left intact. Transcripts are the only
    /// durable record of everything the usage analytics, the sub-agent forest and the workshop
    /// board's session links read, and a migration that turns out to be wrong should cost a
    /// re-point rather than a history.
    public static var `default`: AgentHome {
        AgentHome(root: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".aviary", directoryHint: .isDirectory))
    }

    /// Where Aviary's data used to live, so the app can say so when the new home is empty.
    public static var legacyPrimeHome: AgentHome {
        AgentHome(root: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".prime/agent", directoryHint: .isDirectory))
    }

    public var sessionsDir: URL { root.appending(path: "sessions", directoryHint: .isDirectory) }
    public var artifactsDir: URL { root.appending(path: "session-artifacts", directoryHint: .isDirectory) }
    public var rlmLedgerDir: URL { root.appending(path: "rlm-ledger", directoryHint: .isDirectory) }
    // `workersDir`, `leasesDir`, `logsDir`, `kernelVenv` and `agentLog` were here. All five
    // named directories the harness daemon owned — worker descriptors, ownership leases, its
    // log, and the 297MB IPython venv it built. Nothing in Aviary read any of them by the time
    // the fork was removed, and they were not carried into the new home.

    public var modelsFile: URL { root.appending(path: "models.json") }
    public var settingsFile: URL { root.appending(path: "settings.json") }
    public var authFile: URL { root.appending(path: "auth.json") }
    public var agentsFile: URL { root.appending(path: "AGENTS.md") }

    public var promptsDir: URL { root.appending(path: "prompts", directoryHint: .isDirectory) }
    public var skillsDir: URL { root.appending(path: "skills", directoryHint: .isDirectory) }
    public var extensionsDir: URL { root.appending(path: "extensions", directoryHint: .isDirectory) }
    public var agentProfilesDir: URL { root.appending(path: "agents", directoryHint: .isDirectory) }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    // The supervisor and worker socket paths were here — `$TMPDIR/prime-agent-<uid>`, the
    // daemon socket and the ownership-owner directory inside it. Aviary runs its agents in
    // this process and talks to its runtime host over a pipe, so there is no socket to name.

    public func sessionFile(id: String) -> URL {
        sessionsDir.appending(path: "\(id).jsonl")
    }

    public func artifacts(forSession id: String) -> URL {
        artifactsDir.appending(path: id, directoryHint: .isDirectory)
    }

    public func scheduledJobs(forSession id: String) -> URL {
        artifacts(forSession: id).appending(path: "scheduled-jobs.json")
    }

    /// Where `artifact()` writes documents.
    ///
    /// A subdirectory rather than the session's artifacts root, because that root already
    /// holds machinery — `scheduled-jobs.json`, `sub-*/` child sessions — and the filenames
    /// here are derived from titles a model chose. One report called "Scheduled jobs" should
    /// not be able to land on the file that drives them.
    public func artifactDocuments(forSession id: String) -> URL {
        artifacts(forSession: id).appending(path: "artifacts", directoryHint: .isDirectory)
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
    /// What makes a directory the Aviary repo root.
    ///
    /// The runtime host. This used to look for the vendored harness's `package.json`, which
    /// quietly made *every* engine depend on a fork neither of the surviving two used —
    /// both locate `host.py` through `repoRoot()`, so removing the harness would have broken
    /// them at once. Keying on the thing actually needed is also self-validating: a root
    /// without a runtime host is no use to any caller.
    static let rootMarker = "runtime-hosts/python3/host.py"

    /// Walk up from a starting directory looking for the Aviary repo root.
    public static func repoRoot(startingAt start: URL = URL(fileURLWithPath: Bundle.main.bundlePath)) -> URL? {
        var dir = start
        for _ in 0..<12 {
            let marker = dir.appending(path: rootMarker)
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // Development fallback: the conventional checkout location.
        let conventional = FileManager.default.homeDirectoryForCurrentUser.appending(path: "duckbill/aviary")
        if FileManager.default.fileExists(
            atPath: conventional.appending(path: rootMarker).path) { return conventional }
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

    /// The bundled payload-recording extension, if this checkout has it.
    public static func wireLogExtension() -> URL? {
        guard let root = repoRoot() else { return nil }
        let url = root.appending(path: "harness-extensions/wire-log.ts")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func version(of executable: String, args: [String]) async -> String? {
        guard case .success(let r) = await Shell.run(
            executable, args + ["--version"], timeout: 45), r.ok else { return nil }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
