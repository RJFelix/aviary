import Foundation

/// Result of a finished subprocess.
public struct ProcessResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: TimeInterval

    public var ok: Bool { exitCode == 0 }
    /// stdout if the process succeeded, else stderr — what you want in an error banner.
    public var best: String { ok ? stdout : (stderr.isEmpty ? stdout : stderr) }
}

public enum ShellError: LocalizedError {
    case launchFailed(String, underlying: String)
    case timedOut(String, after: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let cmd, let underlying): return "Could not launch \(cmd): \(underlying)"
        case .timedOut(let cmd, let after): return "\(cmd) did not finish within \(Int(after))s"
        }
    }
}

/// Subprocess helper with the two things Foundation makes annoying: a hard timeout, and
/// an explicit environment.
public enum Shell {
    /// Run to completion, capturing both streams.
    ///
    /// `timeout` is enforced — a hung `lsof` or a wedged `prime-agent doctor` must never
    /// block the UI, and both have been observed hanging in practice.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdin: String? = nil,
        timeout: TimeInterval = 30
    ) async -> Result<ProcessResult, ShellError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                if let cwd { p.currentDirectoryURL = cwd }
                p.environment = environment ?? ProcessEnvironment.shared.snapshot

                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                let inPipe = Pipe()
                if stdin != nil { p.standardInput = inPipe }

                // Drain both pipes concurrently: a child writing more than one pipe
                // buffer to stderr will deadlock if we read stdout to EOF first.
                let sink = StreamSink()
                let group = DispatchGroup()
                for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let d = pipe.fileHandleForReading.readDataToEndOfFile()
                        sink.put(d, isStdout: isOut)
                        group.leave()
                    }
                }

                do {
                    try p.run()
                } catch {
                    continuation.resume(returning: .failure(
                        .launchFailed(executable, underlying: error.localizedDescription)))
                    return
                }

                if let stdin {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }

                let deadline = DispatchWorkItem {
                    if p.isRunning { p.terminate() }
                    // SIGTERM is advisory; something ignoring it still must not hold us.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                p.waitUntilExit()
                _ = group.wait(timeout: .now() + 5)
                deadline.cancel()

                let (o, e) = sink.strings()

                continuation.resume(returning: .success(ProcessResult(
                    stdout: o, stderr: e,
                    exitCode: p.terminationStatus,
                    duration: Date().timeIntervalSince(started))))
            }
        }
    }

    /// Convenience: run and return stdout, or "" on any failure. For probes where
    /// "no answer" and "an error" mean the same thing to the caller.
    public static func capture(
        _ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 15
    ) async -> String {
        guard case .success(let r) = await run(executable, arguments, timeout: timeout) else { return "" }
        return r.stdout
    }

    /// Run a command line through the user's login zsh.
    ///
    /// Needed wherever a tool lives behind a shell-managed PATH (asdf shims, Homebrew,
    /// `~/.local/bin`). `-i` is required: `.zshrc` is only sourced for interactive shells.
    public static func loginShell(_ command: String, timeout: TimeInterval = 30) async
        -> Result<ProcessResult, ShellError>
    {
        await run("/bin/zsh", ["-ilc", command], timeout: timeout)
    }

    public static func which(_ tool: String) async -> String? {
        let r = await capture("/usr/bin/which", [tool], timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty, FileManager.default.isExecutableFile(atPath: r) { return r }
        // Fall back to the login shell, which knows about shims the bare PATH doesn't.
        guard case .success(let res) = await loginShell("command -v \(tool)", timeout: 15) else { return nil }
        let p = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
}

/// Collects two pipe reads happening on different queues.
final class StreamSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aviary.stream-sink")
    private var out = Data()
    private var err = Data()

    func put(_ data: Data, isStdout: Bool) {
        queue.sync { if isStdout { out = data } else { err = data } }
    }

    func strings() -> (String, String) {
        queue.sync {
            (String(data: out, encoding: .utf8) ?? "", String(data: err, encoding: .utf8) ?? "")
        }
    }
}

/// The environment Aviary hands to every child process.
///
/// This exists because of a specific, expensive failure mode. A macOS GUI app inherits
/// launchd's environment, not the one `.zshrc` builds — so an app-launched agent sees no
/// `LITELLM_MASTER_KEY`, no asdf shims, no `~/.local/bin`. Prime Agent resolves a bare
/// environment-variable name in `models.json` *client-side*, and when the variable is
/// absent it does not error: it sends the literal name as the credential, producing a 401
/// that reads like a config typo. The same config works in Terminal and 401s from a GUI.
///
/// So on first use we snapshot the interactive login shell's environment once and use it
/// for the engine, provider tests, and every probe. Aviary behaves as if you had launched
/// it from your terminal, because for these purposes you effectively did.
public final class ProcessEnvironment: @unchecked Sendable {
    public static let shared = ProcessEnvironment()

    private let queue = DispatchQueue(label: "aviary.process-environment")
    private var cached: [String: String]?
    private var loadedFromShell = false

    /// True once the login-shell snapshot succeeded — surfaced in Health so the state is
    /// never a mystery.
    public var isLoginShellEnvironment: Bool {
        queue.sync { loadedFromShell }
    }

    public var snapshot: [String: String] {
        queue.sync {
            if let c = cached { return c }
            let fallback = ProcessInfo.processInfo.environment
            cached = fallback
            return fallback
        }
    }

    /// Load the interactive login shell's environment. Call once at startup; cheap enough
    /// (~150ms) to be worth doing before anything else touches a subprocess.
    @discardableResult
    public func loadFromLoginShell() async -> Bool {
        // NUL-delimited so values containing newlines survive intact.
        let r = await Shell.run(
            "/bin/zsh", ["-ilc", "/usr/bin/env -0"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 20)
        guard case .success(let res) = r, res.ok, !res.stdout.isEmpty else { return false }

        var env = ProcessInfo.processInfo.environment
        for pair in res.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex..<eq])
            let value = String(pair[pair.index(after: eq)...])
            env[key] = value
        }
        queue.sync {
            cached = env
            loadedFromShell = true
        }
        return true
    }

    /// Whether a named variable is present — never its value. Used to answer
    /// "will this provider's apiKey resolve?" without putting a credential in the UI.
    public func has(_ name: String) -> Bool {
        guard let v = snapshot[name] else { return false }
        return !v.isEmpty
    }

    public func value(_ name: String) -> String? {
        let v = snapshot[name]
        return (v?.isEmpty ?? true) ? nil : v
    }
}
