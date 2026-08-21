import SwiftUI
import AppKit
import AviaryCore

/// Filing a request, capturing what Aviary looked like, and handing it to the agent.
///
/// Delivery is two-stage on purpose. The request is appended to the log *first* and
/// unconditionally; only then does Aviary try to reach a session. That ordering is the
/// whole reliability story: no engine, wedged daemon, quit app, or failed launch can lose
/// something you typed, and an undelivered request stays visible on the board as
/// undelivered rather than vanishing. The alternative — send first, record on success —
/// loses exactly the requests you most want to keep, the ones filed when something is
/// already broken.
extension AppModel {

    // MARK: Reading

    func refreshBoard() {
        board = WorkshopBoard.load(repoRoot: repoRoot)
        if let id = selectedRequestID, !board.requests.contains(where: { $0.id == id }) {
            selectedRequestID = board.requests.first?.id
        }
    }

    var selectedRequest: WorkshopRequest? {
        guard let selectedRequestID else { return board.requests.first }
        return board.requests.first { $0.id == selectedRequestID } ?? board.requests.first
    }

    /// The run servicing the board, if one is attached in this app.
    var workshopRun: LiveRun? {
        guard let workshopRunID else { return nil }
        return runs.first { $0.id == workshopRunID }
    }

    /// What to tell the user about the agent's availability, in one line.
    var workshopSessionState: (label: String, tint: Color, isReady: Bool) {
        if let run = workshopRun, !run.hasExited {
            if run.isStreaming { return ("Agent working", Design.success, true) }
            return ("Agent idle, attached", Design.accent, true)
        }
        if let id = workshopSessionID {
            if let live = liveSessions.first(where: { $0.sessionID == id }) {
                return (live.isWorking ? "Agent working elsewhere" : "Session live, not attached",
                        live.isWorking ? Design.success : Design.warning, true)
            }
            if sessions.contains(where: { $0.id == id }) {
                return ("Session on disk, not running", .secondary, true)
            }
            return ("Remembered session is missing", Design.danger, false)
        }
        return ("No workshop session yet", .secondary, false)
    }

    // MARK: Opening the panel

    /// Capture first, then show the composer.
    ///
    /// The order is the whole point. A screenshot taken at submit time contains the compose
    /// panel sitting on top of the thing being reported, and the panel covers the
    /// bottom-right corner of the window — which on this app is real content. Capturing
    /// before the panel is added to the hierarchy costs a few hundred milliseconds of
    /// latency on open and buys an image that is purely what you were looking at.
    ///
    /// The facts are captured here too, for the same reason and for one more: the preview in
    /// the panel then shows exactly what will be filed, rather than a fresh reading that
    /// could differ from it.
    func openCapturePanel() {
        guard !capturePanelOpen, !isCapturingShot else { return }
        pendingContext = captureContext()
        guard draftIncludesShot, let window = NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        else {
            capturePanelOpen = true
            return
        }
        isCapturingShot = true
        Task {
            let data = await WindowShot.capture(window: window)
            pendingShot = data
            isCapturingShot = false
            capturePanelOpen = true
        }
    }

    /// Drop what was captured. Called when the panel is dismissed without filing, so a stale
    /// image can never be attached to a later request.
    func discardPendingCapture() {
        pendingContext = nil
        pendingShot = nil
    }

    // MARK: Filing

    func submitRequest() {
        Task { await submitRequestAsync() }
    }

    private func submitRequestAsync() async {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else { return }
        guard let repoRoot else {
            show("No Aviary checkout found, so there is nowhere to file this.", isError: true)
            return
        }

        isSubmitting = true
        let id = Workshop.newID()
        // Prefer what was captured when the panel opened. The fallback covers a panel opened
        // by some path that did not go through `openCapturePanel`.
        var context = pendingContext ?? captureContext()
        if draftIncludesShot, let data = pendingShot,
           let name = writeShot(data, requestID: id, repoRoot: repoRoot)
        {
            context.screenshot = name
        }

        let kind = draftKind
        do {
            try WorkshopLog.append(
                WorkshopEvent(event: "created", id: id, fields: [
                    "title": .string(title),
                    "body": .string(body),
                    "kind": .string(kind.rawValue),
                    "context": WorkshopLog.encode(context),
                ]),
                repoRoot: repoRoot)
        } catch {
            isSubmitting = false
            show("Could not write to the board: \(error.localizedDescription)", isError: true)
            return
        }

        draftTitle = ""
        draftBody = ""
        discardPendingCapture()
        refreshBoard()
        selectedRequestID = id
        capturePanelOpen = false

        guard let request = board.requests.first(where: { $0.id == id }) else {
            isSubmitting = false
            return
        }
        Task { await deliver(request) }
    }

    /// Hand a request to the workshop session, starting one if there isn't a live one.
    func deliver(_ request: WorkshopRequest) async {
        defer { isSubmitting = false }
        guard let repoRoot else { return }
        let message = request.promptEnvelope(
            logPath: relativeToRepo(Workshop.logURL(repoRoot: repoRoot)),
            briefPath: relativeToRepo(Workshop.briefURL(repoRoot: repoRoot)))

        // Already attached here: the run knows whether it is mid-turn, and a follow-up is
        // the honest verb for "when you are next idle".
        if let run = workshopRun, !run.hasExited {
            if run.isStreaming {
                await run.queueFollowUp(message)
                show("Queued \(request.id) — the agent will pick it up after this turn.")
            } else {
                await run.send(message)
                show("Sent \(request.id) to the workshop agent.")
            }
            markDelivered(request.id, session: run.sessionID)
            return
        }

        guard engine != nil else {
            show("Filed \(request.id). No engine configured, so it was not delivered.", isError: true)
            return
        }

        // Nothing attached. Resume the remembered session, or open a new one, and
        // deliver as the first prompt.
        let resume = workshopSessionID
        var config = RunConfiguration(cwd: repoRoot.path, resume: resume)
        config.environmentOverrides["AVIARY_WORKSHOP"] = "1"

        let first = resume == nil
            ? bootstrapPrompt(repoRoot: repoRoot) + "\n\n---\n\n" + message
            : message

        startRun(config: config, firstPrompt: first)
        workshopRunID = runs.last?.id
        section = .workshop

        // Wait for the engine to prove it is alive before claiming the request was
        // delivered. The first real request was recorded as delivered *and* claimed while
        // the engine had already exited 1 — the board said an agent had it, nothing had it,
        // and the only evidence was a line in the harness's own log. A delivery that cannot
        // fail visibly is worse than no delivery.
        if await engineProvedAlive() {
            markDelivered(request.id, session: workshopRun?.sessionID)
            let id = request.id
            Task { await trackSession(for: id) }
            show(resume == nil
                ? "Opened a workshop session and sent \(request.id)."
                : "Resumed the workshop session and sent \(request.id).")
        } else {
            recordDeliveryFailure(request.id)
        }
    }

    /// Re-send a request that never reached a session.
    func redeliver(_ request: WorkshopRequest) {
        isSubmitting = true
        Task { await deliver(request) }
    }

    /// Record that a request reached an agent — and that it is therefore no longer waiting.
    ///
    /// Aviary writes the `claimed` status itself rather than waiting for the agent to do it.
    /// Handing work to a live agent *is* a state change, and it is one Aviary observes
    /// directly; leaving the card in the inbox until the agent volunteers an event means the
    /// board contradicts the visibly-working session next to it. The agent still owns
    /// `building`, `done` and `declined`, and any event it writes later supersedes this one.
    private func markDelivered(_ id: String, session: String?) {
        guard let repoRoot else { return }
        var fields: [String: JSONValue] = [:]
        if let session { fields["session"] = .string(session) }
        try? WorkshopLog.append(
            WorkshopEvent(event: "delivered", id: id, fields: fields), repoRoot: repoRoot)
        try? WorkshopLog.append(
            WorkshopEvent(event: "status", id: id, fields: [
                "status": .string(WorkshopStatus.claimed.rawValue),
                "note": .string("Handed to the workshop agent."),
                "by": .string("aviary"),
            ]),
            repoRoot: repoRoot)
        refreshBoard()
    }

    /// True once the engine has answered with a session id; false if it exited first.
    ///
    /// A session id is the cheapest available proof of life: it only exists after the engine
    /// has booted node, resolved its model and answered `get_state`.
    private func engineProvedAlive() async -> Bool {
        for _ in 0..<60 {
            guard let run = workshopRun else { return false }
            if let sid = run.sessionID, !sid.isEmpty { return true }
            if run.hasExited { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return workshopRun?.hasExited == false
    }

    /// Leave the request open, and write down why it did not get through.
    ///
    /// Recorded as a `note` rather than a status change: nothing about the request has
    /// changed, only our attempt to hand it over, and the next attempt should find it exactly
    /// where it was.
    private func recordDeliveryFailure(_ id: String) {
        guard let repoRoot else { return }
        let run = workshopRun
        let stderr = (run?.stderrTail ?? []).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let code = run?.exitCode.map { "exit \($0)" } ?? "no exit code"
        let banner = run?.errorBanner
        let detail = [banner, stderr.isEmpty ? nil : String(stderr.suffix(1200))]
            .compactMap { $0 }.joined(separator: "\n")

        var lines = ["Delivery failed — the engine did not start (\(code)). The request is still open."]
        if let remedy = Workshop.remedy(for: detail) { lines.append(remedy) }
        if !detail.isEmpty { lines.append("Engine output:\n\(detail)") }

        try? WorkshopLog.append(
            WorkshopEvent(event: "note", id: id, fields: [
                "text": .string(lines.joined(separator: "\n\n")),
                "by": .string("aviary"),
            ]),
            repoRoot: repoRoot)
        refreshBoard()
        show(Workshop.remedy(for: detail)
            ?? "Filed \(id), but the engine did not start (\(code)). See the note on the card.",
            isError: true)
    }

    /// Follow a freshly-launched run until the engine reports its session id, then link it.
    ///
    /// Separate from delivery on purpose. The id does not exist until the engine has booted
    /// node, opened the kernel and answered `get_state`, which took longer than the ten
    /// seconds delivery used to wait — so the first real request recorded no session at all
    /// and the Receipts card had nothing to link. Blocking longer would have been the wrong
    /// fix: the send has already happened, so this is bookkeeping and belongs off the path.
    private func trackSession(for requestID: String) async {
        guard let repoRoot else { return }
        for _ in 0..<240 {
            if let sid = workshopRun?.sessionID, !sid.isEmpty {
                workshopSessionID = sid
                try? WorkshopLog.append(
                    WorkshopEvent(event: "link", id: requestID, fields: [
                        "session": .string(sid),
                    ]),
                    repoRoot: repoRoot)
                refreshBoard()
                return
            }
            if workshopRun?.hasExited == true { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Change a request's status from the board. Recorded as an event like any other, with
    /// `by: "you"` so the log distinguishes your judgement from the agent's.
    func setStatus(_ status: WorkshopStatus, for request: WorkshopRequest, note: String = "") {
        guard let repoRoot else { return }
        var fields: [String: JSONValue] = [
            "status": .string(status.rawValue),
            "by": .string("you"),
        ]
        if !note.isEmpty { fields["note"] = .string(note) }
        do {
            try WorkshopLog.append(
                WorkshopEvent(event: "status", id: request.id, fields: fields), repoRoot: repoRoot)
            refreshBoard()
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    func addNote(_ text: String, to request: WorkshopRequest) {
        guard let repoRoot, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? WorkshopLog.append(
            WorkshopEvent(event: "note", id: request.id, fields: [
                "text": .string(text), "by": .string("you"),
            ]),
            repoRoot: repoRoot)
        refreshBoard()
    }

    /// Attach to the remembered workshop session without filing anything.
    func attachWorkshopSession() {
        guard let repoRoot, engine != nil else { return }
        if let run = workshopRun, !run.hasExited {
            focusedRunID = run.id
            section = .live
            return
        }
        var config = RunConfiguration(cwd: repoRoot.path, resume: workshopSessionID)
        config.environmentOverrides["AVIARY_WORKSHOP"] = "1"
        startRun(
            config: config,
            firstPrompt: workshopSessionID == nil ? bootstrapPrompt(repoRoot: repoRoot) : nil)
        workshopRunID = runs.last?.id
        Task {
            if let run = workshopRun {
                for _ in 0..<40 where run.sessionID == nil {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if let sid = run.sessionID { workshopSessionID = sid }
            }
        }
    }

    func forgetWorkshopSession() {
        workshopSessionID = nil
        workshopRunID = nil
        show("Forgot the workshop session. The next request opens a fresh one.")
    }

    private func bootstrapPrompt(repoRoot: URL) -> String {
        """
        You are the Aviary workshop agent. This session is long-lived and dedicated to one \
        job: improving Aviary itself, in response to requests filed from inside the running \
        app.

        The checkout is `\(repoRoot.path)`. Read `\(relativeToRepo(Workshop.briefURL(repoRoot: repoRoot)))` \
        now — it is your standing brief and it is authoritative over anything in this message. \
        If it does not exist, read `AGENTS.md` and `docs/architecture.md`, then write the \
        brief yourself and say so.

        Do not start work until you have read the brief.
        """
    }

    func relativeToRepo(_ url: URL) -> String {
        guard let repoRoot else { return url.path }
        let root = repoRoot.path.hasSuffix("/") ? repoRoot.path : repoRoot.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    func screenshotURL(for request: WorkshopRequest) -> URL? {
        guard let repoRoot, let name = request.context?.screenshot else { return nil }
        return Workshop.directory(repoRoot: repoRoot).appending(path: name)
    }

    // MARK: Context capture

    /// Everything Aviary can cheaply say about its own state right now.
    ///
    /// Generous on purpose. A request filed against a GUI is nearly useless without the
    /// state that produced it, that state is unrecoverable ten seconds later, and the
    /// consumer is a model reading prose — so the cost of an irrelevant fact is a line of
    /// text and the cost of a missing one is a round trip.
    func captureContext() -> WorkshopContext {
        var facts: [WorkshopContext.Fact] = []
        func add(_ group: String, _ label: String, _ value: String) {
            guard !value.isEmpty else { return }
            facts.append(WorkshopContext.Fact(group: group, label: label, value: value))
        }

        // Where you were.
        add("Screen", "Tab", section.title)
        add("Screen", "Inspector", showInspector ? "shown" : "hidden")
        if !sessionSearch.isEmpty { add("Screen", "Session filter", sessionSearch) }
        if !transcriptSearch.isEmpty { add("Screen", "Transcript filter", transcriptSearch) }
        if hideThinking { add("Screen", "Thinking blocks", "hidden") }
        if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            add("Screen", "Window", "\(Int(w.frame.width))×\(Int(w.frame.height))")
        }
        if let toast { add("Screen", "Visible message", toast.message) }

        // The build under the request.
        add("Build", "Aviary", Self.appVersion)
        if let engine {
            add("Build", "Engine", "\(engine.kind.label) \(engine.version ?? "unknown version")")
            add("Build", "Engine path", engine.displayPath)
        } else {
            add("Build", "Engine", "none configured")
        }
        add("Build", "Agent directory", home.root.path)
        add("Build", "Login shell env", loginShellEnvironmentLoaded ? "loaded" : "NOT loaded")

        // What the app currently holds.
        add("State", "Sessions in catalog", "\(sessions.count)")
        add("State", "Daemon", daemon.health.label)
        add("State", "Live sessions", "\(liveSessions.count) (\(liveSessions.filter(\.isWorking).count) working)")
        add("State", "Workers", "\(workers.count)")
        if daemon.kernelCount > 0 { add("State", "IPython kernels", "\(daemon.kernelCount)") }
        add("State", "Sub-agents known", "\(tree.allNodes.count) (\(tree.runningCount) running)")
        add("State", "Attached runs", "\(runs.count)")
        if let lastRefresh {
            add("State", "Catalog refreshed", Fmt.timestamp(lastRefresh))
        }
        if let e = catalogError { add("State", "Catalog error", e) }
        if let e = runtimeModelsError { add("State", "Model catalog error", e) }

        // Tab-specific detail: the "what data is there" half of the request.
        switch section {
        case .cockpit:
            add("Cockpit", "Total tokens", Fmt.tokens(analytics.total.totalTokens))
        case .sessions:
            add("Sessions", "Showing", "\(filteredSessions.count) of \(sessions.count)")
            if let s = selectedSession {
                add("Selected session", "Id", s.id)
                add("Selected session", "Title", s.title)
                add("Selected session", "Project", s.projectName)
                add("Selected session", "Working dir", s.cwd)
                add("Selected session", "Model", [s.provider, s.model].compactMap { $0 }.joined(separator: "/"))
                add("Selected session", "Live", s.isLive ? (s.isBusy ? "yes, working" : "yes, idle") : "no")
                if let t = transcript {
                    add("Selected session", "Transcript rows", "\(t.items.count)")
                }
                add("Selected session", "Recorded payloads", "\(selectedSessionWire.count)")
                if let k = kernelState {
                    add("Selected session", "Kernel variables saved", "\(k.savedNames.count)")
                }
            } else {
                add("Sessions", "Selection", "none")
            }
        case .live:
            if let run = focusedRun {
                add("Focused run", "Title", run.title)
                add("Focused run", "Model", run.modelLabel ?? "—")
                add("Focused run", "Streaming", run.isStreaming ? "yes" : "no")
                add("Focused run", "Exited", run.hasExited ? "yes (code \(run.exitCode.map(String.init) ?? "?"))" : "no")
                add("Focused run", "Transcript rows", "\(run.items.count)")
                add("Focused run", "Session id", run.sessionID ?? "not yet assigned")
                add("Focused run", "Working dir", run.config.cwd)
                if let e = run.errorBanner { add("Focused run", "Error banner", e) }
                if let c = run.contextTokens {
                    add("Focused run", "Context", "\(Fmt.tokens(c)) of \(run.contextWindow.map(Fmt.tokens) ?? "?")")
                }
            } else {
                add("Live", "Attached runs", "none")
            }
        case .workshop:
            add("Workshop", "Board", "\(board.openCount) open · \(board.workingCount) in progress · \(board.doneCount) done")
            add("Workshop", "Agent", workshopSessionState.label)
            if let s = selectedRequest { add("Workshop", "Selected request", s.id) }
        case .flock:
            add("Flock", "Nodes", "\(tree.allNodes.count)")
            add("Flock", "Running", "\(tree.runningCount)")
        case .models:
            add("Models", "Reachable", "\(runtimeModels.count)")
            add("Models", "Configured providers", "\(modelsConfig.providers.count)")
            let failed = providerTests.filter { !$0.value.ok }.keys.sorted()
            if !failed.isEmpty { add("Models", "Failing provider tests", failed.joined(separator: ", ")) }
        case .usage:
            add("Usage", "Sessions counted", "\(analytics.sessionCount)")
            add("Usage", "Total tokens", Fmt.tokens(analytics.total.totalTokens))
        case .library:
            add("Library", "Skills", "\(library.skills.count)")
            add("Library", "Prompts", "\(library.prompts.count)")
            add("Library", "Extensions", "\(library.extensions.count)")
        case .health:
            add("Health", "Daemon", daemon.health.label)
            add("Health", "Socket", daemon.socketPath ?? "—")
            if let v = daemon.version { add("Health", "Daemon version", v) }
        }

        return WorkshopContext(
            section: section.rawValue,
            sectionSubtitle: sectionSubtitleForCapture,
            facts: facts)
    }

    /// Duplicates RootView's subtitle intentionally: the capture must not depend on a view
    /// being on screen, because a request can be filed from the menu with no window focused.
    private var sectionSubtitleForCapture: String {
        switch section {
        case .cockpit: return engine.map { "\($0.kind.label) · \($0.version ?? "unknown")" } ?? "No engine"
        case .sessions: return "\(filteredSessions.count) of \(sessions.count)"
        case .live: return "\(liveSessions.count) live · \(runs.count) attached"
        case .workshop: return "\(board.openCount) open · \(board.requests.count) total"
        case .flock: return "\(tree.allNodes.count) sub-agents"
        case .models: return "\(runtimeModels.count) reachable"
        case .usage: return Fmt.tokens(analytics.total.totalTokens) + " tokens"
        case .library: return "\(library.skills.count) skills"
        case .health: return daemon.health.label
        }
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return [v, b.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            .isEmpty ? "development build" : [v, b.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    /// Write an already-captured image to `workshop/shots/`, returning the name relative to
    /// the workshop directory.
    ///
    /// The capture itself happened when the panel opened — see `openCapturePanel`. Failure
    /// here returns nil and the request is filed without an image, never blocked by one.
    func writeShot(_ png: Data, requestID: String, repoRoot: URL) -> String? {
        let dir = Workshop.shotsDirectory(repoRoot: repoRoot)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(requestID).png")
        do {
            try png.write(to: url)
            return "shots/\(requestID).png"
        } catch {
            return nil
        }
    }
}
