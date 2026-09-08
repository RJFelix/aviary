import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AgentHomeError: LocalizedError, Equatable, Sendable {
    case workHostIDNotPersisted
    case workHostIDUnavailable(String)
    case invalidPersistedWorkHostID

    public var errorDescription: String? {
        switch self {
        case .workHostIDNotPersisted:
            return "This AgentHome has no persisted Work Host identity."
        case .workHostIDUnavailable(let reason):
            return "The Work Host identity could not be persisted: \(reason)"
        case .invalidPersistedWorkHostID:
            return "The persisted Work Host identity is invalid."
        }
    }
}

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
    /// Reversible catalog organization. Archiving never moves or rewrites a transcript.
    public var archivedSessionsFile: URL { root.appending(path: "archived-sessions.json") }
    public var authFile: URL { root.appending(path: "auth.json") }
    /// Stable identity for the Work Host represented by this AgentHome.
    ///
    /// It is intentionally a non-secret local record. A future remote host will supply its own
    /// value over the service protocol; local WorkRefs must not all say merely "local".
    public var workHostIDFile: URL {
        root.appending(path: "work-host-id", directoryHint: .notDirectory)
    }

    /// Private storage for the durable GUI/device identity used to attach to the Work service.
    ///
    /// The conventional AgentHome may predate native Work and be mode 0755. Keep the identity
    /// store's strict private-parent contract by giving it a dedicated child rather than chmodding
    /// the whole home or weakening the store. This locator deliberately does not inspect or
    /// migrate the former root-level `work-service-client-id`; migration requires an explicit
    /// identity-preservation policy if a released build ever writes that legacy location.
    public var workServiceClientIdentityDirectory: URL {
        root.appending(path: "work-service-client", directoryHint: .isDirectory)
    }

    public var workServiceClientIdentityFile: URL {
        workServiceClientIdentityDirectory.appending(
            path: "client-id", directoryHint: .notDirectory)
    }

    /// Load or create the durable Work Host identity for this home.
    ///
    /// A stable lock plus synchronized temporary-file publication is used as a create-if-absent
    /// race guard: a second GUI/process that opens the same home reads the winner's id rather than
    /// replacing it. If the home cannot be written, return a process-local fallback and let the
    /// caller surface that degraded durability rather than pretending it is a globally stable host.
    public var workHostID: String {
        if case .valid(let existing) = Self.persistedWorkHostIDState(from: workHostIDFile) {
            return existing
        }
        do {
            return try createPersistedWorkHostID()
        } catch {
            // Keep the degraded value stable for this home even when persistence is unavailable;
            // two accesses must not make one process look like two Work Hosts.
            return "host-unpersisted-\(String(UInt(bitPattern: root.path.hashValue), radix: 16))"
        }
    }

    /// Return the Work Host identity only when a value has been durably created and can be read
    /// back from this home. Unlike workHostID, this API never returns the process-local
    /// hashValue fallback and is therefore the only suitable source for native authority.
    public func requirePersistedWorkHostID() throws -> String {
        switch Self.readPersistedWorkHostIDWithRetry(from: workHostIDFile) {
        case .valid(let existing):
            return existing
        case .malformed:
            throw AgentHomeError.invalidPersistedWorkHostID
        case .missing:
            return try createPersistedWorkHostID()
        }
    }

    /// The persisted authority as a typed identity.
    public func requirePersistedWorkHost() throws -> WorkHostRef {
        WorkHostRef(try requirePersistedWorkHostID())
    }

    /// Read the persisted id without manufacturing a fallback. This is useful for diagnostics
    /// that need to distinguish an empty/uninitialised home from a host that is ready to own Work.
    public var persistedWorkHostID: String? {
        if case .valid(let value) = Self.persistedWorkHostIDState(from: workHostIDFile) {
            return value
        }
        return nil
    }

    private enum PersistedWorkHostIDState {
        case missing
        case malformed
        case valid(String)
    }

    private var workHostIDLockFile: URL {
        root.appending(path: "work-host-id.lock", directoryHint: .notDirectory)
    }

    /// The identity is a local authority, not an arbitrary label. Keep its wire representation
    /// deliberately small and restricted to the format this home mints (`host-<UUID>`). Besides
    /// making malformed records fail closed, this bounds all diagnostics and avoids accepting
    /// path/control characters from a hand-edited or corrupted authority file.
    private static let persistedWorkHostIDMaximumBytes = 128

    private static func isValidPersistedWorkHostID(_ value: String) -> Bool {
        guard value.utf8.count <= persistedWorkHostIDMaximumBytes,
              value.hasPrefix("host-") else {
            return false
        }

        let suffix = String(value.dropFirst("host-".count))
        let scalars = Array(suffix.unicodeScalars)
        guard scalars.count == 36 else { return false }

        for (index, scalar) in scalars.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard scalar.value == 0x2D else { return false }
            } else {
                let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
                let isLowerHex = scalar.value >= 0x61 && scalar.value <= 0x66
                guard isDigit || isLowerHex else { return false }
            }
        }
        return UUID(uuidString: suffix) != nil
    }

    private static func persistedWorkHostIDState(from url: URL) -> PersistedWorkHostIDState {
        // Do not use String(contentsOf:) here: this file is an authority boundary, so a corrupt
        // multi-megabyte record must not be materialized merely to discover that it is too large.
        let maximumFramedBytes = persistedWorkHostIDMaximumBytes + 2 // optional CRLF framing
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let bounded = try handle.read(
                upToCount: maximumFramedBytes + 1) else {
                return .malformed
            }
            guard bounded.count <= maximumFramedBytes else { return .malformed }
            data = bounded
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .malformed : .missing
        }
        guard let existing = String(data: data, encoding: .utf8) else {
            return .malformed
        }

        // The file is newline-terminated by the publisher. Accept exactly one LF (or CRLF)
        // framing suffix, but do not trim arbitrary spaces or additional records: otherwise two
        // distinct on-disk authorities could be silently treated as the same value.
        var candidate = existing
        if candidate.hasSuffix("\n") {
            candidate.removeLast()
            if candidate.hasSuffix("\r") { candidate.removeLast() }
        }
        guard !candidate.isEmpty,
              !candidate.contains("\n"), !candidate.contains("\r"),
              candidate == candidate.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isValidPersistedWorkHostID(candidate) else {
            return .malformed
        }
        return .valid(candidate)
    }

    /// A competing first-use caller can observe the exclusive file while its winner is still
    /// writing the short record. Give that in-process/cross-process race a bounded read-back
    /// window; a missing or permanently malformed record still fails explicitly.
    private static func readPersistedWorkHostIDWithRetry(from url: URL) -> PersistedWorkHostIDState {
        var lastState = PersistedWorkHostIDState.missing
        for attempt in 0..<20 {
            let state = persistedWorkHostIDState(from: url)
            if case .valid = state { return state }
            lastState = state
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.001) }
        }
        return lastState
    }

    /// Serialize first-use creation and publish a complete, synchronized record without ever
    /// replacing an existing authority. The temporary file is linked into place atomically;
    /// a crash can leave an orphan temp file, but cannot leave the authority file half-written.
    private func createPersistedWorkHostID() throws -> String {
        try withWorkHostIDLock {
            switch Self.persistedWorkHostIDState(from: workHostIDFile) {
            case .valid(let existing):
                return existing
            case .malformed:
                throw AgentHomeError.invalidPersistedWorkHostID
            case .missing:
                break
            }

            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw AgentHomeError.workHostIDUnavailable(error.localizedDescription)
            }

            let generated = "host-\(UUID().uuidString.lowercased())"
            let temporary = root.appending(
                path: ".work-host-id-\(UUID().uuidString.lowercased()).tmp",
                directoryHint: .notDirectory)
            defer { try? FileManager.default.removeItem(at: temporary) }

            guard FileManager.default.createFile(
                atPath: temporary.path, contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
                throw AgentHomeError.workHostIDUnavailable("could not create temporary identity")
            }
            let temporaryHandle: FileHandle
            do {
                temporaryHandle = try FileHandle(forWritingTo: temporary)
                try temporaryHandle.write(contentsOf: Data((generated + "\n").utf8))
                try temporaryHandle.synchronize()
                try temporaryHandle.close()
            } catch {
                throw AgentHomeError.workHostIDUnavailable(error.localizedDescription)
            }

            let linkResult = temporary.path.withCString { source in
                workHostIDFile.path.withCString { destination in
                    link(source, destination)
                }
            }
            guard linkResult == 0 else {
                let code = errno
                if code == EEXIST {
                    if case .valid(let existing) = Self.persistedWorkHostIDState(from: workHostIDFile) {
                        return existing
                    }
                    throw AgentHomeError.invalidPersistedWorkHostID
                }
                throw AgentHomeError.workHostIDUnavailable(
                    "could not publish identity: \(String(cString: strerror(code)))")
            }

            // The link is the atomic publication point. Fsync the containing directory before
            // reporting success so a power loss cannot acknowledge an identity whose directory
            // entry was still only in the filesystem cache.
            try Self.synchronizeDirectory(containing: workHostIDFile)

            guard case .valid(let persisted) = Self.persistedWorkHostIDState(from: workHostIDFile) else {
                throw AgentHomeError.workHostIDUnavailable("the published identity could not be read back")
            }
            return persisted
        }
    }

    private static func synchronizeDirectory(containing fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY)
        }
        guard descriptor >= 0 else {
            throw AgentHomeError.workHostIDUnavailable(
                "could not open identity directory for synchronization: \(String(cString: strerror(errno)))")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw AgentHomeError.workHostIDUnavailable(
                "could not synchronize identity directory: \(String(cString: strerror(errno)))")
        }
    }

    private func withWorkHostIDLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw AgentHomeError.workHostIDUnavailable(error.localizedDescription)
        }

        let descriptor = workHostIDLockFile.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT, mode: mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw AgentHomeError.workHostIDUnavailable(
                "could not lock authority creation: \(String(cString: strerror(errno)))")
        }
        let lock = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? lock.close() }
        return try body()
    }
    public var agentsFile: URL { root.appending(path: "AGENTS.md") }

    public var promptsDir: URL { root.appending(path: "prompts", directoryHint: .isDirectory) }
    public var skillsDir: URL { root.appending(path: "skills", directoryHint: .isDirectory) }
    public var extensionsDir: URL { root.appending(path: "extensions", directoryHint: .isDirectory) }
    public var agentProfilesDir: URL { root.appending(path: "agents", directoryHint: .isDirectory) }

    // MARK: Timeline v2 locators

    /// Timeline v2 deliberately has its own tree. These URLs are locators only; the journal
    /// owner and authority remain encoded in JournalRef, not inferred from a path.
    public var timelineV2Dir: URL {
        root.appending(path: "timeline-v2", directoryHint: .isDirectory)
    }

    public var timelineV2Root: URL { timelineV2Dir }

    public var timelineV2SessionsDir: URL {
        timelineV2Dir.appending(path: "sessions", directoryHint: .isDirectory)
    }

    public var timelineV2WorkHostsDir: URL {
        timelineV2Dir.appending(path: "work-hosts", directoryHint: .isDirectory)
    }

    /// Persistent advisory locks live outside owner directories. If a journal directory is
    /// renamed or replaced, the same owner still resolves to the same lock inode.
    public var timelineV2LocksDir: URL {
        timelineV2Dir.appending(path: "locks", directoryHint: .isDirectory)
    }

    /// Return the lock-file locator for the data path's collision domain.
    ///
    /// Data locators intentionally omit Session authority and journal ID, so those values must
    /// not create a second lock namespace. An identity mismatch is instead rejected when a
    /// non-empty journal is read. Work identity includes its Work Host because bare Work IDs are
    /// not globally unique.
    public func timelineV2JournalLockURL(for journal: JournalRef) -> URL {
        let ownerKey: String
        let kind: TimelineJournalKind
        switch journal.owner {
        case .session(let session):
            kind = .session
            ownerKey = "session\u{00}\(session.sessionID.utf8.count):\(session.sessionID)"
        case .work(let work):
            kind = .work
            ownerKey = "work\u{00}\(work.workHostID.utf8.count):\(work.workHostID)"
                + "\u{00}\(work.workID.utf8.count):\(work.workID)"
        case .workHost(let workHost):
            kind = .workHost
            ownerKey = "work-host\u{00}\(workHost.workHostID.utf8.count):\(workHost.workHostID)"
        }
        let digest = AviarySHA256.hash(data: Data(ownerKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return timelineV2LocksDir
            .appending(path: kind.rawValue, directoryHint: .isDirectory)
            .appending(path: "\(digest).lock", directoryHint: .notDirectory)
    }

    /// Encode a caller-controlled id as one path component. Safe, common ids remain readable;
    /// every other byte is hex-encoded behind a reserved prefix, so slash, dot-dot, NUL, and
    /// Unicode normalization cannot escape or alias a directory.
    public static func timelineV2PathComponent(_ value: String) -> String {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return "~empty" }
        let safe = bytes.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D || byte == 0x5F
        }
        if safe { return value }
        return "~" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func timelineV2SessionJournalURL(sessionID: String) -> URL {
        timelineV2SessionsDir
            .appending(path: Self.timelineV2PathComponent(sessionID),
                       directoryHint: .isDirectory)
            .appending(path: "journal.jsonl", directoryHint: .notDirectory)
    }

    public func timelineV2SessionJournalURL(_ session: SessionRef) -> URL {
        timelineV2SessionJournalURL(sessionID: session.sessionID)
    }

    public func timelineV2WorkJournalURL(workHostID: String, workID: String) -> URL {
        timelineV2WorkHostsDir
            .appending(path: Self.timelineV2PathComponent(workHostID),
                       directoryHint: .isDirectory)
            .appending(path: "works", directoryHint: .isDirectory)
            .appending(path: Self.timelineV2PathComponent(workID),
                       directoryHint: .isDirectory)
            .appending(path: "journal.jsonl", directoryHint: .notDirectory)
    }

    public func timelineV2WorkJournalURL(_ work: WorkRef) -> URL {
        timelineV2WorkJournalURL(workHostID: work.workHostID, workID: work.workID)
    }

    /// Native Work creation must use this throwing locator so an unwritable home cannot silently
    /// turn a process-local hash into journal authority.
    public func timelineV2WorkJournalURL(workID: String) throws -> URL {
        let hostID = try requirePersistedWorkHostID()
        return timelineV2WorkJournalURL(workHostID: hostID, workID: workID)
    }

    public func timelineV2SessionJournal(sessionID: String) -> URL {
        timelineV2SessionJournalURL(sessionID: sessionID)
    }

    public func timelineV2WorkJournal(workHostID: String, workID: String) -> URL {
        timelineV2WorkJournalURL(workHostID: workHostID, workID: workID)
    }

    /// The Work Host control journal is separate from every Work journal. Its durable records
    /// describe client attachments and read acknowledgements, so observing completed Work can
    /// advance this journal without mutating the immutable Work outcome.
    public func timelineV2WorkHostControlJournalURL(workHostID: String) -> URL {
        timelineV2WorkHostsDir
            .appending(path: Self.timelineV2PathComponent(workHostID), directoryHint: .isDirectory)
            .appending(path: "control", directoryHint: .isDirectory)
            .appending(path: "journal.jsonl", directoryHint: .notDirectory)
    }

    public func timelineV2WorkHostControlJournalURL(_ workHost: WorkHostRef) -> URL {
        timelineV2WorkHostControlJournalURL(workHostID: workHost.workHostID)
    }

    public func timelineV2WorkHostControlJournal(_ workHost: WorkHostRef) -> URL {
        timelineV2WorkHostControlJournalURL(workHost)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    // The supervisor and worker socket paths were here — `$TMPDIR/prime-agent-<uid>`, the
    // daemon socket and the ownership-owner directory inside it. Runtime-host sockets now live
    // in the host's dedicated Application Support directory (`Aviary/k`) and are named by its
    // adoption descriptor rather than by this durable work home.

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

    /// Find only an Aviary source checkout. Callers that need the shipped Python runtime rather
    /// than other repository content should use ``runtimeRoot(startingAt:)`` so a bundled daemon
    /// does not accidentally depend on the developer's checkout remaining at a conventional path.

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

    /// Find the directory which owns `runtime-hosts/` in either a source checkout or an app
    /// bundle. This convenience is intentionally only a local source/build inspection helper;
    /// a launched Work Host should use ``runtimeRoot(forExecutable:)`` so a damaged bundle can
    /// never fall through to a developer checkout.
    public static func runtimeRoot(
        startingAt start: URL = URL(fileURLWithPath: Bundle.main.bundlePath)
    ) -> URL? {
        var dir = start.standardizedFileURL
        for _ in 0..<12 {
            if isRuntimeRoot(dir, requireCheckout: false) { return dir }

            let resources = dir.appending(path: "Contents/Resources", directoryHint: .isDirectory)
            if isRuntimeRoot(resources, requireCheckout: false) { return resources }

            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // Never consult a conventional checkout here. A path-independent caller must provide
        // its actual executable origin; guessing `~/duckbill/aviary` is exactly the stale-host
        // fallback this locator is intended to prevent.
        return nil
    }

    /// Resolve runtime assets for the executable which will own a Work Host.
    ///
    /// A bundled helper is coupled to its own app's `Contents/Resources` payload. It is never
    /// allowed to search ancestors or a source checkout when that payload is absent or damaged.
    /// A SwiftPM product is accepted only when it is visibly below `.build` and its enclosing
    /// Aviary checkout contains both the runtime marker and the package manifest. This keeps a
    /// copied executable from silently acquiring a different checkout's Python host.
    public static func runtimeRoot(forExecutable executable: URL) -> URL? {
        let executable = executable.standardizedFileURL
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              !executable.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        var executableInfo = stat()
        guard executable.path.withCString({ lstat($0, &executableInfo) }) == 0,
              (executableInfo.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        if let contents = bundleContents(containing: executable) {
            let resources = contents.appending(
                path: "Resources", directoryHint: .isDirectory)
            return isRuntimeRoot(resources, requireCheckout: false) ? resources : nil
        }

        let components = executable.path.split(separator: "/").map(String.init)
        guard components.contains(".build") else { return nil }
        guard let checkout = repoRootWithoutFallback(
            startingAt: executable.deletingLastPathComponent()) else { return nil }
        return isRuntimeRoot(checkout, requireCheckout: true) ? checkout : nil
    }

    private static func bundleContents(containing executable: URL) -> URL? {
        let components = executable.standardizedFileURL.path.split(separator: "/")
            .map(String.init)
        guard let contentsIndex = components.lastIndex(of: "Contents"), contentsIndex > 0,
              contentsIndex + 1 < components.count,
              (components[contentsIndex + 1] == "Helpers"
                || components[contentsIndex + 1] == "MacOS"),
              components[contentsIndex - 1].hasSuffix(".app") else {
            return nil
        }
        guard !bundleOriginPathContainsSymlink(components) else { return nil }
        var contents = executable.standardizedFileURL
        while contents.lastPathComponent != "Contents" {
            let parent = contents.deletingLastPathComponent()
            guard parent.path != contents.path else { return nil }
            contents = parent
        }
        return contents
    }

    private static func bundleOriginPathContainsSymlink(_ components: [String]) -> Bool {
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else {
            return false
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            guard index >= appIndex else { continue }
            var information = stat()
            guard lstat(current.path, &information) == 0 else { continue }
            if information.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private static func repoRootWithoutFallback(startingAt start: URL) -> URL? {
        var dir = start.standardizedFileURL
        for _ in 0..<12 {
            if isRuntimeRoot(dir, requireCheckout: true) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func isRuntimeRoot(_ root: URL, requireCheckout: Bool) -> Bool {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.isEmpty else { return false }
        // Check only the origin-relative path.  Rejecting every symlink back to `/` would reject
        // normal macOS aliases such as `/var`, while accepting a symlinked `runtime-hosts` would
        // let a bundled helper acquire Python code from an unrelated checkout.
        guard directoryIsReal(root) else { return false }
        let runtimeHosts = root.appending(path: "runtime-hosts", directoryHint: .isDirectory)
        let runtimeVariant = runtimeHosts.appending(path: "python3", directoryHint: .isDirectory)
        guard directoryIsReal(runtimeHosts), directoryIsReal(runtimeVariant) else { return false }
        let marker = runtimeVariant.appending(path: "host.py", directoryHint: .notDirectory)
        var markerInfo = stat()
        guard marker.path.withCString({ lstat($0, &markerInfo) }) == 0,
              (markerInfo.st_mode & S_IFMT) == S_IFREG,
              markerInfo.st_mode & mode_t(0o444) != 0 else { return false }
        if requireCheckout {
            let package = root.appending(path: "app/Package.swift", directoryHint: .notDirectory)
            var packageInfo = stat()
            guard package.path.withCString({ lstat($0, &packageInfo) }) == 0,
                  (packageInfo.st_mode & S_IFMT) == S_IFREG else { return false }
        }
        return true
    }

    private static func directoryIsReal(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
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
