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
    case cancelled(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let cmd, let underlying): return "Could not launch \(cmd): \(underlying)"
        case .timedOut(let cmd, let after): return "\(cmd) did not finish within \(Int(after))s"
        case .cancelled(let cmd): return "\(cmd) was cancelled"
        }
    }
}

/// Crosses the async caller and the blocking subprocess queue.  In particular, timeout
/// and cancellation are recorded separately from the child's eventual termination status:
/// a process killed by our deadline is not a successful `ProcessResult` merely because its
/// exit status happens to be readable.
private final class ShellRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var didTimeout = false
    private var didCancel = false
    private var completed = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = didCancel
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    /// Returns true when the caller won the race with normal process completion and the
    /// worker should arrange a bounded TERM -> KILL escalation.
    func requestTimeout() -> Bool {
        lock.lock()
        guard !completed, let process, process.isRunning else {
            lock.unlock()
            return false
        }
        didTimeout = true
        lock.unlock()
        process.terminate()
        return true
    }

    /// Cancellation is deliberately cooperative at the async boundary but forceful at the
    /// process boundary. The worker still owns continuation resumption, so there is no
    /// second continuation race when cancellation arrives before launch.
    func requestCancellation() -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        didCancel = true
        let process = self.process
        lock.unlock()
        process?.terminate()
        return true
    }

    func forceKillIfRunning() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    func finish(command: String, timeout: TimeInterval) -> ShellError? {
        lock.lock()
        completed = true
        let result: ShellError?
        if didTimeout {
            result = .timedOut(command, after: timeout)
        } else if didCancel {
            result = .cancelled(command)
        } else {
            result = nil
        }
        lock.unlock()
        return result
    }
}

/// Subprocess helper with the two things Foundation makes annoying: a hard timeout, and
/// an explicit environment.
public enum Shell {
    /// Run to completion, capturing both streams.
    ///
    /// `timeout` is enforced — a hung diagnostic or child process must never block the UI.
    /// Deadline and task cancellation return `ShellError` failures; a normally launched
    /// process (including one that exits from a signal) remains a `ProcessResult`.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdin: String? = nil,
        timeout: TimeInterval = 30
    ) async -> Result<ProcessResult, ShellError> {
        let control = ShellRunControl()
        return await withTaskCancellationHandler(operation: {
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
                // A GUI-launched process can inherit the app's controlling terminal when
                // `standardInput` is left unset. In particular, an interactive login shell
                // then tries to acquire terminal job control and can be stopped (rather than
                // exiting) when this work runs on a background queue. Commands that do not
                // receive input must always be detached from that terminal. Keep the pipe
                // path for callers that explicitly provide stdin.
                p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

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
                control.attach(p)

                if let stdin {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }

                let deadline = DispatchWorkItem {
                    if control.requestTimeout() {
                        // SIGTERM is advisory; something ignoring it still must not hold us.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            control.forceKillIfRunning()
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                p.waitUntilExit()
                _ = group.wait(timeout: .now() + 5)
                deadline.cancel()

                let (o, e) = sink.strings()

                if let error = control.finish(command: executable, timeout: timeout) {
                    continuation.resume(returning: .failure(error))
                    return
                }

                continuation.resume(returning: .success(ProcessResult(
                    stdout: o, stderr: e,
                    exitCode: p.terminationStatus,
                    duration: Date().timeIntervalSince(started))))
                }
            }
        }, onCancel: {
            if control.requestCancellation() {
                // Cancellation can happen while Process.run is still being reached, so the
                // delayed escalation is scheduled even when no process was attached yet.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    control.forceKillIfRunning()
                }
            }
        })
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
    /// `~/.local/bin`). Use a non-interactive login shell: forcing `-i` on a child launched
    /// from a GUI/background queue can make zsh attempt terminal job control and stop itself.
    /// Source `.zshrc` explicitly because non-interactive shells do not source it.
    public static func loginShell(_ command: String, timeout: TimeInterval = 30) async
        -> Result<ProcessResult, ShellError>
    {
        let startup = "if [ -r \"${ZDOTDIR:-$HOME}/.zshrc\" ]; then source \"${ZDOTDIR:-$HOME}/.zshrc\" >/dev/null 2>&1; fi"
        return await run("/bin/zsh", ["-lc", "\(startup); \(command)"], timeout: timeout)
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
/// So on first use we snapshot the configured login shell's environment once and use it
/// for the engine, provider tests, and every probe. Aviary behaves as if you had launched
/// it from your terminal, because for these purposes you effectively did.
public final class ProcessEnvironment: @unchecked Sendable {
    public static let shared = ProcessEnvironment()

    private let queue = DispatchQueue(label: "aviary.process-environment")
    private var cached: [String: String]?
    private var loadedFromShell = false
    private var loadTask: Task<Bool, Never>?

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

    /// Load the configured login shell's environment. Call once at startup; cheap enough
    /// (~150ms) to be worth doing before anything else touches a subprocess.
    @discardableResult
    public func loadFromLoginShell() async -> Bool {
        let task: Task<Bool, Never>? = queue.sync {
            if loadedFromShell { return nil }
            if let loadTask { return loadTask }

            // NUL-delimited so values containing newlines survive intact. A failed attempt
            // deliberately clears `loadTask` without changing the fallback snapshot, so a
            // transient shell/launch failure can be retried by the next caller.
            let task = Task { [weak self] () -> Bool in
                let r = await Shell.run(
                    "/bin/zsh", ["-lc", "if [ -r \"${ZDOTDIR:-$HOME}/.zshrc\" ]; then source \"${ZDOTDIR:-$HOME}/.zshrc\" >/dev/null 2>&1; fi; /usr/bin/env -0"],
                    environment: ProcessInfo.processInfo.environment,
                    timeout: 20)
                guard case .success(let res) = r, res.ok, !res.stdout.isEmpty else {
                    self?.queue.sync {
                        self?.loadTask = nil
                    }
                    return false
                }

                var env = ProcessInfo.processInfo.environment
                for pair in res.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
                    guard let eq = pair.firstIndex(of: "=") else { continue }
                    let key = String(pair[pair.startIndex..<eq])
                    let value = String(pair[pair.index(after: eq)...])
                    env[key] = value
                }
                self?.queue.sync {
                    self?.cached = env
                    self?.loadedFromShell = true
                    self?.loadTask = nil
                }
                return true
            }
            loadTask = task
            return task
        }

        // A successful prior load is the only case where no task is returned. Do not create
        // an already-completed Task here: this keeps the one-shot/coalesced state explicit.
        guard let task else { return true }
        return await task.value
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
