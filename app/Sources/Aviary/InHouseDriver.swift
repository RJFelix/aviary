import SwiftUI
import AviaryCore

/// Drives an in-house run for the Live view.
///
/// The transcript comes from tailing the session file the run writes, not from a second
/// rendering path. That is the whole reason `SessionWriter` reuses the harness's format: one
/// parser, one renderer, and a live run that looks identical to the same run read back
/// tomorrow. The only thing layered on top is the text of the turn currently streaming, which
/// is not on disk yet because an entry is written when a turn completes.
@Observable
@MainActor
final class InHouseDriver {
    /// Everything the run has written, re-parsed as it grows.
    var items: [TranscriptItem] = []
    /// The assistant text of the turn in flight, before it becomes an entry.
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

    private let home: AgentHome
    private let cwd: String
    private let model: ModelSpec
    private let providerSpec: ProviderSpec
    private var host: RuntimeHost?
    private var runner: AgentRunner?
    private var writer: SessionWriter?
    private var watcher: SessionWatcher?
    private var task: Task<Void, Never>?
    /// Kept so the run can take another prompt. The loop is per-prompt; the conversation,
    /// the runtime session and its Python state all persist across them — which is the whole
    /// reason a session is worth more than a request.
    private var agent: Agent?
    private(set) var acceptsFollowUps = false

    init(home: AgentHome, cwd: String, model: ModelSpec, providerSpec: ProviderSpec) {
        self.home = home
        self.cwd = cwd
        self.model = model
        self.providerSpec = providerSpec
    }

    func start(prompt: String) {
        task = Task { await run(prompt: prompt) }
    }

    private func run(prompt: String) async {
        guard let repoRoot = EngineLocator.repoRoot() else {
            errorBanner = "No Aviary checkout, so there is no runtime host."
            hasExited = true
            return
        }
        guard let baseURL = providerSpec.baseURL.flatMap(URL.init(string:)) else {
            errorBanner = "Provider \(providerSpec.id) has no baseUrl."
            hasExited = true
            return
        }

        let script = repoRoot.appending(path: "runtime-hosts/python3/host.py")
        let host = RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", script.path])
        self.host = host
        do {
            let capabilities = try await host.start()
            runtimeSummary = capabilities.summary
        } catch {
            errorBanner = "Could not start the runtime host: \(error.localizedDescription)"
            hasExited = true
            return
        }

        let key = await AgentCLI.resolvedSecret(providerSpec.apiKeyExpression)
        let provider: ChatProvider = providerSpec.api == "anthropic-messages"
            ? AnthropicMessagesProvider(
                id: providerSpec.id, baseURL: baseURL, apiKey: key,
                extraHeaders: providerSpec.headers)
            : OpenAICompletionsProvider(
                id: providerSpec.id, baseURL: baseURL, apiKey: key,
                extraHeaders: providerSpec.headers)

        // Skills, gated. Reported so the saving is visible rather than assumed.
        let settings = HarnessSettings.load(home: home)
        let library = Library.discover(
            home: home, settings: settings,
            projectRoot: URL(fileURLWithPath: cwd), enginePackageRoot: nil)
        let gate = SkillGate()
        let selection = gate.select(skills: library.skills, prompt: prompt, cwd: cwd)
        if !library.skills.isEmpty {
            skillsNote = "\(selection.included.count) of \(library.skills.count) skills described"
                + " · \(Fmt.bytes(selection.savedCharacters)) saved"
        }

        let memory = MemoryStore(repoRoot: repoRoot, home: home, cwd: cwd)
        let memoryGate = MemoryGate()
        let recalled = memoryGate.select(memory.load(sessionID: nil), prompt: prompt)
        if recalled.totalAvailable > 0 {
            memoryNote = "\(recalled.included.count) memories recalled"
                + (recalled.listed.isEmpty ? "" : ", \(recalled.listed.count) listed")
        }

        let runner = AgentRunner(
            provider: provider, host: host,
            settings: .init(
                home: home, cwd: cwd, model: model,
                systemPrompt: SystemPrompt.build(
                    cwd: cwd, model: model, skills: gate.render(selection),
                    memory: memoryGate.render(recalled)),
                memory: memory))
        self.runner = runner

        await runner.observe { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }

        isStreaming = true
        do {
            let (writer, agent) = try await runner.run(prompt: prompt)
            self.writer = writer
            self.agent = agent
            acceptsFollowUps = true
            usage = await agent.totalUsage
        } catch {
            errorBanner = error.localizedDescription
            hasExited = true
        }
        isStreaming = false
        // Not exited: the conversation, the interpreter and its variables are all still here,
        // so the run stays open for a follow-up rather than being torn down after one prompt.
        reload()
    }

    private func ingest(_ event: Agent.Event) {
        switch event {
        case .started(let session):
            sessionID = session
            sessionFile = home.sessionFile(id: session)
            follow()
        case .textDelta(let t):
            streamingText += t
        case .thinkingDelta(let t):
            streamingThinking += t
        case .turnFinished:
            // The turn is on disk now, so the file is the source of truth for it and the
            // streaming buffer would only duplicate it.
            streamingText = ""
            streamingThinking = ""
            reload()
        case .toolStarted, .toolFinished, .compacted, .childStarted, .childFinished:
            reload()
        case .finished:
            isStreaming = false
            reload()
        case .failed(let detail):
            errorBanner = detail
            isStreaming = false
            reload()
        }
    }

    /// Watch the file so entries appear as they are appended, including from sub-agents.
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

    /// Another prompt in the same session — same conversation, same interpreter, same
    /// variables.
    func send(_ prompt: String) {
        guard let agent, !isStreaming else { return }
        task = Task {
            isStreaming = true
            await agent.send(prompt)
            usage = await agent.totalUsage
            isStreaming = false
            reload()
        }
    }

    func stop() {
        task?.cancel()
        watcher?.stop()
        let host = self.host
        Task {
            await self.writer?.close()
            await host?.stop()
        }
        hasExited = true
        isStreaming = false
    }
}
