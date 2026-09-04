import Darwin
import Foundation

/// The two locations in which Aviary is allowed to find its local Work Host daemon.
///
/// This is intentionally not a general executable locator.  In particular, it never consults
/// `PATH`, a login shell, or an arbitrary configured path: doing so would let a shell shim or an
/// unrelated binary become the process which owns this AgentHome's Work Host journals.
public enum LocalAviaryDaemonExecutableOrigin: String, Codable, Hashable, Sendable {
    case appBundleHelper
    case swiftPMBuildSibling
}

/// The result of resolving `aviaryd`, retained as a small diagnostic value so callers can show
/// where the daemon came from without reimplementing the bundle/SwiftPM layout rules.
public struct LocalAviaryDaemonExecutable: Codable, Hashable, Sendable {
    public let url: URL
    public let origin: LocalAviaryDaemonExecutableOrigin

    public init(url: URL, origin: LocalAviaryDaemonExecutableOrigin) {
        self.url = url
        self.origin = origin
    }
}

/// Explicit, non-secret failures from local daemon resolution or spawn.
///
/// Error values deliberately do not carry a candidate path.  A path can expose a user's home,
/// workspace layout, or a private checkout in a notification or a remote receipt.
public enum LocalAviaryDaemonLauncherError: Error, LocalizedError, Equatable, Sendable {
    case invalidAgentHome
    case invalidWorkspace
    case executableNotFound
    case executablePathInvalid
    case executableSymlink
    case executableNotRegular
    case executableNotExecutable
    case launchFailed
    case canceled

    public var errorDescription: String? {
        switch self {
        case .invalidAgentHome:
            return "The local Work Host AgentHome path is invalid."
        case .invalidWorkspace:
            return "The explicit local Work Host workspace path is invalid."
        case .executableNotFound:
            return "The Aviary Work Host executable was not found in an approved location."
        case .executablePathInvalid:
            return "The Aviary Work Host executable path is invalid."
        case .executableSymlink:
            return "The Aviary Work Host executable must not be a symlink."
        case .executableNotRegular:
            return "The Aviary Work Host executable is not a regular file."
        case .executableNotExecutable:
            return "The Aviary Work Host executable is not executable."
        case .launchFailed:
            return "The Aviary Work Host process could not be started."
        case .canceled:
            return "Local Work Host launch was canceled before the process was started."
        }
    }
}

/// Starts the local `aviaryd` process without owning it.
///
/// The GUI is a client of a Work Host, not the Work Host's lifetime owner.  This value therefore
/// has no `Process` property, no termination handler, no parent-lease argument, and no deinit
/// cleanup.  `launch()` returns immediately after `Process.run()` succeeds; discovery and the
/// protocol handshake remain the responsibility of ``LocalWorkServiceBootstrap``.
public struct LocalAviaryDaemonLauncher: Sendable {
    public static let maximumPathBytes = 4 * 1024

    private struct Candidate: Sendable {
        let url: URL
        let origin: LocalAviaryDaemonExecutableOrigin
    }

    public let agentHome: AgentHome
    public let workspace: URL?

    private let sourceExecutableURL: URL

    /// Create a launcher using the running GUI's executable location to select the daemon.
    ///
    /// `sourceExecutableURL` is injectable for deterministic tests and for a host that has a
    /// known executable location.  It is still only used to derive the two approved layouts;
    /// it is never executed and it cannot turn this API into a PATH or arbitrary-path lookup.
    public init(
        agentHome: AgentHome,
        workspace: URL? = nil,
        sourceExecutableURL: URL? = nil
    ) throws {
        let validatedHome = try Self.validateAgentHome(agentHome)
        let validatedWorkspace = try Self.validateWorkspace(workspace)
        self.agentHome = validatedHome
        self.workspace = validatedWorkspace
        self.sourceExecutableURL = (sourceExecutableURL ?? Self.currentExecutableURL())
            .standardizedFileURL
    }

    /// The closure shape consumed directly by ``LocalWorkServiceBootstrap``.
    public func asLauncher() -> LocalWorkServiceBootstrap.Launcher {
        { [self] in try await self.launch() }
    }

    /// Convenience for callers constructing a bootstrapper inline.
    public static func makeLauncher(
        agentHome: AgentHome,
        workspace: URL? = nil,
        sourceExecutableURL: URL? = nil
    ) throws -> LocalWorkServiceBootstrap.Launcher {
        try Self(
            agentHome: agentHome,
            workspace: workspace,
            sourceExecutableURL: sourceExecutableURL).asLauncher()
    }

    /// Resolve the approved daemon executable without starting it.
    public func resolveExecutable() throws -> LocalAviaryDaemonExecutable {
        for candidate in Self.candidates(from: sourceExecutableURL) {
            switch Self.inspect(candidate.url) {
            case .missing:
                continue
            case .invalidPath:
                throw LocalAviaryDaemonLauncherError.executablePathInvalid
            case .symlink:
                throw LocalAviaryDaemonLauncherError.executableSymlink
            case .notRegular:
                throw LocalAviaryDaemonLauncherError.executableNotRegular
            case .notExecutable:
                throw LocalAviaryDaemonLauncherError.executableNotExecutable
            case .valid:
                return LocalAviaryDaemonExecutable(
                    url: candidate.url.standardizedFileURL,
                    origin: candidate.origin)
            }
        }
        throw LocalAviaryDaemonLauncherError.executableNotFound
    }

    /// Spawn the daemon and return after successful admission to the operating system.
    ///
    /// All three standard streams are `/dev/null`: no pipe is left for a GUI to stop draining,
    /// and closing a GUI cannot deliver EOF to or block the daemon.  The daemon has its own
    /// durable endpoint and journal, so this function intentionally does not retain `Process`
    /// or install a termination handler.  The only arguments are the explicit AgentHome and,
    /// when supplied by a host administrator, the explicit workspace selection.
    public func launch() async throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw LocalAviaryDaemonLauncherError.canceled
        }
        let executable = try resolveExecutable()
        var arguments = ["--agent-home", agentHome.root.standardizedFileURL.path]
        if let workspace {
            arguments += ["--workspace", workspace.standardizedFileURL.path]
        }

        let process = Process()
        process.executableURL = executable.url
        process.arguments = arguments
        // Do not let the daemon accidentally use the caller's workspace as an implicit source
        // of configuration or registration.  Its resolver receives explicit paths and its
        // runtime root comes from the executable layout.
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // Do not expose Foundation's underlying string: it can include a full local path.
            throw LocalAviaryDaemonLauncherError.launchFailed
        }
        // `process` intentionally goes out of scope.  Foundation's spawned child is not owned
        // by this launcher, and no cancellation/deinitialization path may send it a signal.
    }

    private enum Inspection {
        case missing
        case invalidPath
        case symlink
        case notRegular
        case notExecutable
        case valid
    }

    private static func inspect(_ url: URL) -> Inspection {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.isEmpty,
              url.path.utf8.count <= maximumPathBytes,
              !url.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return .invalidPath
        }
        // Do not let an approved-looking `.build` or `.app` path redirect through a symlinked
        // parent after candidate derivation.  System aliases above those roots (for example
        // `/var` on macOS) are intentionally outside this check; this is path-integrity
        // hardening, not a claim that Process.run provides an atomic cwd/executable lease.
        if approvedOriginPathContainsSymlink(url) { return .symlink }
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            return errno == ENOENT ? .missing : .notRegular
        }
        let type = information.st_mode & S_IFMT
        if type == S_IFLNK { return .symlink }
        guard type == S_IFREG else { return .notRegular }
        // Check both the mode bits and the effective access.  The mode check keeps this truthful
        // when the test process happens to run with elevated privileges; access() catches a
        // regular file whose effective owner/group cannot execute it.
        guard information.st_mode & mode_t(0o111) != 0,
              access(url.path, X_OK) == 0 else {
            return .notExecutable
        }
        return .valid
    }

    private static func approvedOriginPathContainsSymlink(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.path.split(separator: "/").map(String.init)
        let startIndex: Int
        if let index = components.lastIndex(where: { $0.hasSuffix(".app") }) {
            startIndex = index
        } else if let index = components.lastIndex(of: ".build") {
            startIndex = index
        } else {
            return false
        }

        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            guard index >= startIndex else { continue }
            var information = stat()
            guard lstat(current.path, &information) == 0 else {
                // Missing parents are reported by the ordinary candidate inspection below. Do
                // not turn a missing executable into a misleading symlink diagnosis.
                continue
            }
            if information.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private static func candidates(from source: URL) -> [Candidate] {
        let source = source.standardizedFileURL
        var candidates: [Candidate] = []
        let components = source.path.split(separator: "/").map(String.init)

        // `/.../Aviary.app/Contents/MacOS/Aviary` ->
        // `/.../Aviary.app/Contents/Helpers/aviaryd`.
        if components.count >= 3,
           let macOSIndex = components.lastIndex(of: "MacOS"),
           macOSIndex > 0,
           components[macOSIndex - 1] == "Contents",
           macOSIndex + 2 == components.count,
           components[..<(macOSIndex - 1)].last?.hasSuffix(".app") == true {
            let contents = source
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(Candidate(
                url: contents.appending(path: "Helpers/aviaryd", directoryHint: .notDirectory),
                origin: .appBundleHelper))
        }

        // SwiftPM places every product beside its sibling product in both
        // `.build/debug/` and `.build/<triple>/<configuration>/`.  Requiring a `.build`
        // component prevents an arbitrary executable directory from becoming an approved host.
        if components.contains(".build") {
            candidates.append(Candidate(
                url: source.deletingLastPathComponent()
                    .appending(path: "aviaryd", directoryHint: .notDirectory),
                origin: .swiftPMBuildSibling))
        }
        return candidates
    }

    private static func currentExecutableURL() -> URL {
        if let executable = Bundle.main.executableURL { return executable }
        if let argument = CommandLine.arguments.first, !argument.isEmpty {
            return URL(fileURLWithPath: argument)
        }
        // This can only be reached by a malformed embedding process.  It produces a normal
        // `executableNotFound` result rather than making URL construction itself trap.
        return URL(fileURLWithPath: "/")
    }

    private static func validateAgentHome(_ home: AgentHome) throws -> AgentHome {
        guard let path = validatePath(home.root, requireExistingDirectory: false) else {
            throw LocalAviaryDaemonLauncherError.invalidAgentHome
        }
        var information = stat()
        if lstat(path.path, &information) == 0 {
            guard information.st_mode & S_IFMT == S_IFDIR else {
                throw LocalAviaryDaemonLauncherError.invalidAgentHome
            }
            guard information.st_mode & S_IFMT != S_IFLNK else {
                throw LocalAviaryDaemonLauncherError.invalidAgentHome
            }
        } else if errno != ENOENT {
            throw LocalAviaryDaemonLauncherError.invalidAgentHome
        }
        return AgentHome(root: path)
    }

    private static func validateWorkspace(_ workspace: URL?) throws -> URL? {
        guard let workspace else { return nil }
        guard let path = validatePath(workspace, requireExistingDirectory: true) else {
            throw LocalAviaryDaemonLauncherError.invalidWorkspace
        }
        var information = stat()
        guard lstat(path.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_mode & S_IFMT != S_IFLNK else {
            throw LocalAviaryDaemonLauncherError.invalidWorkspace
        }
        return path
    }

    private static func validatePath(
        _ url: URL,
        requireExistingDirectory: Bool
    ) -> URL? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL
        guard path.path.hasPrefix("/"),
              !path.path.isEmpty,
              path.path.utf8.count <= maximumPathBytes,
              !path.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        if requireExistingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
        }
        return path
    }
}
