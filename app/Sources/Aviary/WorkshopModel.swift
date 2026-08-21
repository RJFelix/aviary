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

    // MARK: Filing

    func submitRequest() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else { return }
        guard let repoRoot else {
            show("No Aviary checkout found, so there is nowhere to file this.", isError: true)
            return
        }

        isSubmitting = true
        let id = Workshop.newID()
        var context = captureContext()
        if draftIncludesShot, let name = writeWindowShot(requestID: id, repoRoot: repoRoot) {
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

        // The session id only exists once the engine has answered `get_state`.
        if let run = workshopRun {
            for _ in 0..<40 where run.sessionID == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if let sid = run.sessionID {
                workshopSessionID = sid
                markDelivered(request.id, session: sid)
            } else {
                markDelivered(request.id, session: nil)
            }
        }
        show(resume == nil
            ? "Opened a workshop session and sent \(request.id)."
            : "Resumed the workshop session and sent \(request.id).")
    }

    /// Re-send a request that never reached a session.
    func redeliver(_ request: WorkshopRequest) {
        isSubmitting = true
        Task { await deliver(request) }
    }

    private func markDelivered(_ id: String, session: String?) {
        guard let repoRoot else { return }
        var fields: [String: JSONValue] = [:]
        if let session { fields["session"] = .string(session) }
        try? WorkshopLog.append(
            WorkshopEvent(event: "delivered", id: id, fields: fields), repoRoot: repoRoot)
        refreshBoard()
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

    /// Rasterize the front window into `workshop/shots/`.
    ///
    /// `cacheDisplay` on our own view rather than a screen capture: it needs no screen-
    /// recording permission, cannot pick up anything outside Aviary, and is the same path
    /// `--snapshot` already uses. Returns the name relative to the workshop directory.
    func writeWindowShot(requestID: String, repoRoot: URL) -> String? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView,
              view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
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
