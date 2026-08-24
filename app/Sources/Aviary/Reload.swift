import SwiftUI
import AppKit
import AviaryCore

/// Rebuilding and relaunching Aviary when the workshop has changed Aviary.
///
/// The workshop agent edits this app's own source, so the result of a request is invisible
/// until the binary is rebuilt and the process replaced. Quitting, rebuilding by hand and
/// reopening is three steps and a lost train of thought, for a change you asked for and are
/// waiting on.
///
/// This is not hot reload in the code-injection sense — the process is replaced, not patched.
/// That needs `-Xlinker -interposable` and an injection framework, and there is no Xcode on
/// this machine to hang one off. What makes it feel like a reload rather than a restart is
/// that the slow part has already happened: the build starts the moment the request finishes,
/// while you are still doing something else, so the click itself is immediate — and the app
/// comes back on the screen you were on with the agent reattached.
///
/// One fact makes it possible at all: SwiftPM can relink `Aviary` while `Aviary` is running.
/// Verified rather than assumed — the linker writes and renames, and macOS permits renaming
/// over the file backing a running image.
///
/// The decisions live in `WorkshopReload`, in the core, where they are tested without a
/// window. This is the part that touches processes and the screen.
@Observable
@MainActor
final class Reloader {

    enum Phase: Equatable {
        case idle
        case building(request: String, title: String)
        /// Built, and the executable genuinely moved. Relaunching will show something new.
        case ready(request: String, title: String)
        /// Built, and the executable is where it was — a documentation-only or board-only
        /// request. Said, rather than offering a restart that would change nothing.
        case unchanged(request: String, title: String)
        case failed(request: String, title: String, detail: String)

        var isBusy: Bool { if case .building = self { return true }; return false }

        var requestID: String? {
            switch self {
            case .idle: return nil
            case .building(let id, _), .ready(let id, _),
                 .unchanged(let id, _), .failed(let id, _, _):
                return id
            }
        }
    }

    var phase: Phase = .idle

    /// Watch the board and rebuild on completion. On by default: a background `swift build`
    /// costs nothing you notice, and having the build already done is the whole reason the
    /// reload feels immediate.
    var isEnabled: Bool = UserDefaults.standard.object(forKey: "aviary.reload.enabled") as? Bool
        ?? true
    {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "aviary.reload.enabled")
            if isEnabled { restartWatching() } else { stop(); phase = .idle }
        }
    }

    /// Replace the process the moment a build succeeds, without asking.
    ///
    /// Off by default, for a specific reason rather than out of caution: right after the
    /// workshop agent finishes a request, the session that finished it is usually still
    /// attached and holding a live interpreter. Relaunching ends it. That is recoverable — the
    /// transcript is on disk and the session can be resumed — but losing an interpreter's
    /// variables out from under you unannounced is not a good default.
    var autoRelaunch: Bool = UserDefaults.standard.bool(forKey: "aviary.reload.auto") {
        didSet { UserDefaults.standard.set(autoRelaunch, forKey: "aviary.reload.auto") }
    }

    /// How long the last build took, shown so an unusually slow one reads as unusual.
    private(set) var lastBuildDuration: TimeInterval?
    private(set) var launchMode: WorkshopReload.LaunchMode?

    /// Set by `AppModel`, which owns what has to be written down before the process goes.
    var requestRelaunch: (@MainActor () -> Void)?

    private var repoRoot: URL?
    private var watcher: SessionWatcher?
    private var lastSeen: [String: WorkshopStatus] = [:]
    private var onBoardChange: (@MainActor () -> Void)?
    private var buildTask: Task<Void, Never>?

    // MARK: Watching

    /// Start watching, taking the current board as the baseline.
    ///
    /// The baseline is the point: without it every request that was already done before launch
    /// reads as a fresh completion, and the app rebuilds itself every time it starts.
    func begin(
        repoRoot: URL?, board: WorkshopBoard, onBoardChange: @MainActor @escaping () -> Void
    ) {
        self.repoRoot = repoRoot
        self.onBoardChange = onBoardChange
        self.launchMode = WorkshopReload.launchMode(
            executablePath: Bundle.main.executablePath ?? "",
            bundlePath: Bundle.main.bundlePath,
            hasCheckout: repoRoot != nil)
        lastSeen = WorkshopReload.completion(board: board, lastSeen: [:]).lastSeen
        Self.probe("begin mode=\(launchMode?.describedTarget ?? "none") "
            + "enabled=\(isEnabled) auto=\(autoRelaunch) baseline=\(lastSeen.count)")
        if isEnabled { restartWatching() }
    }

    private func restartWatching() {
        stop()
        guard let repoRoot, launchMode != nil else { Self.probe("restartWatching: no repoRoot/mode"); return }
        Self.probe("watching \(Workshop.logURL(repoRoot: repoRoot).path)")
        let w = SessionWatcher(url: Workshop.logURL(repoRoot: repoRoot))
        w.start { [weak self] in
            // The board belongs to the app, not to this object: one reader for the log means
            // the Workshop tab and this banner cannot disagree about what it says.
            // Logged on both sides of the actor hop on purpose. When this stopped firing
            // once, the two candidates were "the watcher missed the write" and "the watcher
            // fired and the main actor never ran the work", and a probe on only one side
            // cannot tell them apart.
            Self.probe("watcher tick")
            Task { @MainActor in Self.probe("board reload"); self?.onBoardChange?() }
        }
        watcher = w
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        buildTask?.cancel()
        buildTask = nil
    }

    /// Called with the freshly loaded board. Starts a build if a request just finished.
    @discardableResult
    func boardChanged(_ board: WorkshopBoard) -> WorkshopRequest? {
        let (completed, seen) = WorkshopReload.completion(board: board, lastSeen: lastSeen)
        lastSeen = seen
        Self.probe("board n=\(board.requests.count) "
            + "completed=\(completed?.id ?? "none") busy=\(phase.isBusy)")
        guard isEnabled, let completed, !phase.isBusy else { return completed }
        build(for: completed)
        return completed
    }

    // MARK: Building

    /// Diagnostics under `AVIARY_RELOAD_DEBUG`, the same arrangement as
    /// `AVIARY_CAPTURE_DEBUG` and `AVIARY_CLAUDE_RAW`.
    ///
    /// Kept because this path is invisible by construction: it runs while you are looking at
    /// something else, and its most likely failure is doing nothing at all. There is no
    /// symptom to notice — so the way to ask "did it see the request finish?" has to exist.
    nonisolated static func probe(_ text: String) {
        guard ProcessInfo.processInfo.environment["AVIARY_RELOAD_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data(("[reload] " + text + "\n").utf8))
    }

    func build(for request: WorkshopRequest) {
        guard let repoRoot, let mode = launchMode else { Self.probe("build: no repoRoot/mode"); return }
        Self.probe("building \(request.id)")
        let title = request.title.isEmpty ? request.id : request.title
        phase = .building(request: request.id, title: title)
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let started = Date()
            let before = WorkshopReload.stamp(ofFileAt: mode.executablePath)
            let command = WorkshopReload.buildCommand(for: mode, repoRoot: repoRoot)
            // A build is minutes, not seconds, so the default timeout would report a working
            // build as a failure.
            let result = await Shell.run(
                command.executable, command.arguments, cwd: command.cwd,
                environment: ProcessEnvironment.shared.snapshot, timeout: 900)
            guard let self, !Task.isCancelled else { return }
            self.lastBuildDuration = Date().timeIntervalSince(started)

            guard case .success(let run) = result else {
                self.phase = .failed(
                    request: request.id, title: title,
                    detail: "Could not run \(command.executable).")
                return
            }
            guard run.ok else {
                self.phase = .failed(
                    request: request.id, title: title,
                    detail: WorkshopReload.firstErrors(in: run.stdout + "\n" + run.stderr))
                return
            }
            let after = WorkshopReload.stamp(ofFileAt: mode.executablePath)
            self.phase = WorkshopReload.binaryChanged(before: before, after: after)
                ? .ready(request: request.id, title: title)
                : .unchanged(request: request.id, title: title)
            // `before`/`after` are here because a comment-only change compiles to a
            // byte-identical object, llbuild skips the relink, and the executable keeps its
            // mtime — which reads exactly like the trigger not having worked.
            Self.probe("\(self.phase) in \(Int((self.lastBuildDuration ?? 0) * 1000))ms "
                + "before=\(before ?? "nil") after=\(after ?? "nil")")
            if case .ready = self.phase, self.autoRelaunch { self.requestRelaunch?() }
        }
    }

    // MARK: Relaunching

    /// Replace this process with a freshly built one.
    ///
    /// The dance is necessary rather than clever: macOS activates the existing instance
    /// instead of starting a second one with the same bundle identifier, so the new app cannot
    /// start until this one is gone — and this one cannot start anything after it has exited.
    /// So a detached shell waits for this pid to disappear, then launches.
    func relaunch() -> Bool {
        guard let mode = launchMode else { return false }
        let pid = ProcessInfo.processInfo.processIdentifier
        let launch: String
        switch mode {
        case .bundle(let path):
            launch = "/usr/bin/open " + Self.quote(path)
        case .binary(let path, _):
            // Redirected and backgrounded: a bare binary relaunched from a terminal must not
            // hold that terminal open, and it has no console to write to anyway.
            launch = Self.quote(path) + " >/dev/null 2>&1 &"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.15; done; \(launch)",
        ]
        // Detached from our streams, so it is not holding anything of ours open when we go.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }

        NSApp.terminate(nil)
        return true
    }

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// Reload probe: removed immediately after the test.
