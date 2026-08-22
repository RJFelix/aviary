import SwiftUI
import AviaryCore

/// Drives a Claude-Code-driven run for the Live view.
///
/// Deliberately the same shape as `InHouseDriver`, down to the property names, because the
/// transcript comes from the same place: the session file the run writes, re-parsed as it
/// grows. One parser, one renderer, and a driven run that reads identically to an in-house one
/// when it is opened again tomorrow. What differs is only what a driven run can be told — there
/// is no steering, because Claude Code owns the turn boundary and will not take an injection
/// mid-turn.
@Observable
@MainActor
final class ClaudeCodeDriver {
    var items: [TranscriptItem] = []
    var streamingText = ""
    var streamingThinking = ""
    var isStreaming = false
    var hasExited = false
    var usage = Usage()
    var sessionID: String?
    var sessionFile: URL?
    var errorBanner: String?
    var runtimeSummary: String?
    var skillsNote: String?
    var memoryNote: String?
    /// Claude Code's own session id. Shown because it is what `claude --resume` takes, and a
    /// person debugging a driven run will want to open it in Claude Code itself.
    var claudeSessionID: String?
    /// Which bucket the run is drawing on. The reason this session type exists, so it is
    /// stated rather than assumed.
    var rateLimit: ClaudeCode.Frame.RateLimit?
    var authSummary: String?
    /// Warnings that are true for the whole run: a leaked API key, a missing tool, a denial.
    var warnings: [String] = []

    private let home: AgentHome
    private let cwd: String
    private let model: String
    private let effort: String?
    private var host: RuntimeHost?
    private var run: ClaudeCodeRun?
    private var bridge: KernelBridge?
    private var watcher: SessionWatcher?
    private var task: Task<Void, Never>?
    private(set) var acceptsFollowUps = false

    init(home: AgentHome, cwd: String, model: String, effort: String? = nil) {
        self.home = home
        self.cwd = cwd
        self.model = model
        self.effort = effort
    }

    func start(prompt: String) {
        task = Task { await launch(prompt: prompt) }
    }

    private func launch(prompt: String) async {
        // The path to this very binary, which Claude Code re-launches as the MCP courier.
        // `Bundle.main.executablePath` rather than `CommandLine.arguments[0]`: inside an app
        // bundle the latter can be relative, and Claude Code resolves an MCP server command in
        // its own working directory, not ours.
        guard let selfPath = Bundle.main.executablePath ?? CommandLine.arguments.first else {
            fail("Could not determine Aviary's own path, which the MCP bridge needs.")
            return
        }

        let bridge = KernelBridge()
        self.bridge = bridge
        let prepared: ClaudeCodeSession.Prepared
        do {
            // The same assembly `--claude-code` uses, deliberately: two copies of this is how a
            // windowed run and a terminal run quietly stop being the same thing.
            prepared = try await ClaudeCodeSession.prepare(
                home: home, cwd: cwd, model: model, effort: effort,
                bridgeExecutable: selfPath, firstPrompt: prompt, bridge: bridge)
        } catch {
            fail(error.localizedDescription)
            return
        }

        host = prepared.host
        run = prepared.run
        authSummary = prepared.auth.summary
        runtimeSummary = prepared.runtimeSummary
        skillsNote = prepared.skillsNote
        memoryNote = prepared.memoryNote
        warnings.append(contentsOf: prepared.warnings)

        await prepared.run.observe { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }

        isStreaming = true
        do {
            try await prepared.run.start(prompt: prompt)
            acceptsFollowUps = true
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func ingest(_ event: ClaudeCodeRun.Event) {
        switch event {
        case .started(let session):
            sessionID = session
            sessionFile = home.sessionFile(id: session)
            follow()
        case .claudeSession(let id):
            claudeSessionID = id
        case .textDelta(let text):
            streamingText += text
        case .thinkingDelta(let text):
            streamingThinking += text
        case .toolStarted:
            reload()
        case .toolFinished:
            // The turn is on disk now, so the buffers would only duplicate what the file says.
            streamingText = ""
            streamingThinking = ""
            reload()
        case .turnFinished:
            streamingText = ""
            streamingThinking = ""
            isStreaming = false
            reload()
        case .rateLimit(let limit):
            rateLimit = limit
        case .warning(let text):
            if !warnings.contains(text) { warnings.append(text) }
            reload()
        case .failed(let detail):
            errorBanner = detail
            isStreaming = false
            reload()
        case .finished:
            isStreaming = false
            hasExited = true
            reload()
        }
    }

    /// Another prompt in the same session — same Claude Code history, same interpreter.
    ///
    /// Claude Code takes this as a new user turn on the history it already holds, which is the
    /// one thing its stream-json input *does* accept.
    func send(_ prompt: String) {
        guard let run, !isStreaming else { return }
        Task {
            isStreaming = true
            await run.send(prompt)
        }
    }

    func stop() {
        task?.cancel()
        watcher?.stop()
        let run = self.run
        let host = self.host
        Task {
            await run?.stop()
            await host?.stop()
        }
        hasExited = true
        isStreaming = false
    }

    private func fail(_ detail: String) {
        errorBanner = detail
        hasExited = true
        isStreaming = false
    }

    private func follow() {
        guard let sessionFile else { return }
        watcher?.stop()
        let w = SessionWatcher(url: sessionFile)
        w.start { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher = w
        reload()
    }

    private func reload() {
        guard let sessionFile else { return }
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                SessionParser.parse(fileURL: sessionFile)
            }.value
            await MainActor.run {
                if let parsed {
                    self.items = parsed.items
                    if parsed.usage.totalTokens > 0 { self.usage = parsed.usage }
                }
            }
        }
    }
}
