import AppKit
import AviaryCore
import SwiftUI

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
        // One reader for the log, so the board and the reload banner cannot disagree about
        // what it says. This is also what starts a rebuild when a request becomes done.
        reloader.boardChanged(board)
    }

    var selectedRequest: WorkshopRequest? {
        guard let selectedRequestID else { return board.requests.first }
        return board.requests.first { $0.id == selectedRequestID } ?? board.requests.first
    }

    /// The run servicing the board, if one is attached in this app.
    var workshopRun: LiveRun? {
        guard let workshopRunID else { return nil }
        return workRuns.first { $0.id == workshopRunID }
    }

    /// What to tell the user about the agent's availability, in one line.
    var workshopSessionState: (label: String, tint: Color, isReady: Bool) {
        if let run = workshopRun, !run.hasExited {
            if run.isStreaming { return ("Agent working", Design.success, true) }
            return ("Agent idle, attached", Design.accent, true)
        }
        if let id = workshopSessionID {
            // No "running elsewhere" case any more: with the supervisor gone, a session is
            // either one of this process's runs — handled above — or a file on disk.
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
        guard draftIncludesShot,
            let window = NSApp.keyWindow
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

    /// Open the Workshop's full-size editor for a new request. It captures before presenting
    /// for the same reason as the global quick-capture panel: the sheet itself must not be
    /// the screenshot attached to the request.
    func openWorkshopEditor() {
        guard workshopEditor == nil, !isCapturingShot else { return }
        pendingContext = captureContext()
        pendingShot = nil
        draftIncludesShot = true
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            workshopEditor = .new
            return
        }
        isCapturingShot = true
        Task {
            pendingShot = await WindowShot.capture(window: window)
            isCapturingShot = false
            workshopEditor = .new
        }
    }

    func closeWorkshopEditor() {
        workshopEditor = nil
        discardPendingCapture()
    }

    func submitRequest() {
        submitRequest(title: draftTitle, body: draftBody, kind: draftKind)
    }

    func submitRequest(title rawTitle: String, body rawBody: String, kind: WorkshopKind) {
        Task { await submitRequestAsync(title: rawTitle, body: rawBody, kind: kind) }
    }

    private func submitRequestAsync(
        title rawTitle: String, body rawBody: String, kind: WorkshopKind
    )
        async
    {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
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

        do {
            try WorkshopLog.append(
                WorkshopEvent(
                    event: "created", id: id,
                    fields: [
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
        workshopEditor = nil

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
            let wasStreaming = run.isStreaming
            let receipt: LiveRunCommandResult
            if wasStreaming {
                receipt = await run.queueFollowUp(message)
            } else {
                receipt = await run.send(message)
            }
            guard receipt.wasHandedOff else {
                let detail = receipt.detail ?? "the Work did not accept the input"
                recordAttachedHandoff(
                    request.id, note: "Delivery was not confirmed: \(detail)")
                show(
                    "Filed \(request.id), but delivery was not confirmed. The request remains open.",
                    isError: true)
                return
            }
            if receipt.isQueued {
                // Queue ownership is real, but it is not durable input delivery. Leave the
                // request open; when the agent consumes the prompt it can claim the card using
                // the request envelope it received.
                recordAttachedHandoff(
                    request.id,
                    note: "Queued to the attached workshop Work; awaiting agent acknowledgement.")
                show("Queued \(request.id). It remains open until the agent acknowledges it.")
                return
            }
            show("Sent \(request.id) to the workshop agent.")
            markDelivered(request.id, session: run.sessionID)
            return
        }

        guard canRunWorkshopAgent else {
            show(
                "Filed \(request.id). No engine configured, so it was not delivered.", isError: true
            )
            return
        }

        // Nothing attached. Resume the remembered session, or open a new one, and
        // deliver as the first prompt.
        let resume = workshopSessionID
        let first: String?
        if resume == nil {
            first = bootstrapPrompt(repoRoot: repoRoot) + "\n\n---\n\n" + message
        } else if engineChoice == .claudeCode {
            // Claude Code cannot be cold-reopened by Aviary, so this path creates a fresh
            // process and still needs this request as its first prompt.
            first = message
        } else {
            first = nil
        }

        // Reopening a remembered Session is not itself delivery. The old in-process path
        // focused the existing run and then the caller treated its historical first message
        // as proof that this new Workshop request arrived. Keep the launch/reopen boundary
        // separate: after the attachment is available, send this request and inspect its own
        // receipt.
        startWorkshopRun(repoRoot: repoRoot, resume: resume, firstPrompt: first)
        section = .workshop

        if resume != nil && engineChoice == .inHouse {
            guard let run = await waitForWorkshopRunAssociation() else {
                recordDeliveryFailure(request.id)
                return
            }
            let wasHandedOff = await handoffWorkshopMessage(
                requestID: request.id, message: message, to: run)
            if !wasHandedOff {
                return
            }
            return
        }

        // Wait for Work to acknowledge the first input at its durable delivery seam before
        // claiming the request. Allocating a session proves only preparation: a process may
        // fail between that point and recording/writing the message.
        if await initialRequestWasDelivered() {
            markDelivered(request.id, session: workshopRun?.sessionID)
            let id = request.id
            Task { await trackSession(for: id) }
            show(
                resume == nil
                ? "Opened a workshop session and sent \(request.id)."
                : "Reopened the workshop conversation in a new runtime and sent \(request.id).")
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
            WorkshopEvent(
                event: "status", id: id,
                fields: [
                "status": .string(WorkshopStatus.claimed.rawValue),
                "note": .string("Handed to the workshop agent."),
                "by": .string("aviary"),
            ]),
            repoRoot: repoRoot)
        refreshBoard()
    }

    /// True only when the first prompt crossed the driver's durable delivery seam.
    ///
    /// Session allocation, process preparation, and input delivery are deliberately separate
    /// outcomes. This prevents Workshop from claiming a request whose Work exists but never
    /// received the request.
    private func initialRequestWasDelivered() async -> Bool {
        for _ in 0..<60 {
            if let run = workshopRun {
                if run.initialPromptDelivered { return true }
                if run.hasExited || run.errorBanner != nil || run.commandState == .failed {
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Wait for a run row to become associated with a newly restored/created Workshop Work.
    /// Association can legitimately lag the service admission response, so a missing row is
    /// not an immediate delivery failure. The bounded timeout still reports a real launch or
    /// catalog problem instead of waiting forever.
    private func waitForWorkshopRunAssociation() async -> LiveRun? {
        for _ in 0..<60 {
            if let run = workshopRun, !run.hasExited { return run }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// Deliver a Workshop request to an already-associated run and preserve the service
    /// receipt's exact handed-off/queued distinction. In particular, a historical Session
    /// message or a successful reopen does not count as delivery for this request.
    private func handoffWorkshopMessage(
        requestID: String, message: String, to run: LiveRun
    ) async -> Bool {
        let receipt: LiveRunCommandResult
        if run.isStreaming {
            receipt = await run.queueFollowUp(message)
        } else {
            receipt = await run.send(message)
        }
        guard receipt.wasHandedOff else {
            let detail = receipt.detail ?? "the Work did not accept the input"
            recordAttachedHandoff(
                requestID, note: "Delivery was not confirmed: \(detail)")
            show(
                "Filed \(requestID), but delivery was not confirmed. The request remains open.",
                isError: true)
            return false
        }
        if receipt.isQueued {
            recordAttachedHandoff(
                requestID,
                note: "Queued to the attached workshop Work; awaiting agent acknowledgement.")
            show("Queued \(requestID). It remains open until the agent acknowledges it.")
            return true
        }
        markDelivered(requestID, session: run.sessionID)
        show("Sent \(requestID) to the workshop agent.")
        return true
    }

    /// Leave the request open, and write down why it did not get through.
    ///
    /// Recorded as a `note` rather than a status change: nothing about the request has
    /// changed, only our attempt to hand it over, and the next attempt should find it exactly
    /// where it was.
    private func recordDeliveryFailure(_ id: String) {
        guard let repoRoot else { return }
        let run = workshopRun
        let stderr = (run?.stderrTail ?? []).joined().trimmingCharacters(
            in: .whitespacesAndNewlines)
        let code = run?.exitCode.map { "exit \($0)" } ?? "no exit code"
        let banner = run?.errorBanner
        let detail = [banner, stderr.isEmpty ? nil : String(stderr.suffix(1200))]
            .compactMap { $0 }.joined(separator: "\n")

        var lines = [
            "Delivery failed — the engine did not start (\(code)). The request is still open."
        ]
        if let remedy = Workshop.remedy(for: detail) { lines.append(remedy) }
        if !detail.isEmpty { lines.append("Engine output:\n\(detail)") }

        try? WorkshopLog.append(
            WorkshopEvent(
                event: "note", id: id,
                fields: [
                "text": .string(lines.joined(separator: "\n\n")),
                "by": .string("aviary"),
            ]),
            repoRoot: repoRoot)
        refreshBoard()
        show(
            Workshop.remedy(for: detail)
            ?? "Filed \(id), but the engine did not start (\(code)). See the note on the card.",
            isError: true)
    }

    /// Record an attached-Work handoff without pretending queue ownership is delivery.
    private func recordAttachedHandoff(_ id: String, note: String) {
        guard let repoRoot else { return }
        try? WorkshopLog.append(
            WorkshopEvent(
                event: "note", id: id,
                fields: [
                    "text": .string(note),
                    "by": .string("aviary"),
                ]),
            repoRoot: repoRoot)
        refreshBoard()
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
                    WorkshopEvent(
                        event: "link", id: requestID,
                        fields: [
                            "session": .string(sid)
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
            WorkshopEvent(
                event: "note", id: request.id,
                fields: [
                "text": .string(text), "by": .string("you"),
            ]),
            repoRoot: repoRoot)
        refreshBoard()
    }

    /// Amend request text without ever rewriting the original event or its captured context.
    /// A later `edited` event is the board's durable, reviewable source of truth.
    func updateRequest(
        _ request: WorkshopRequest, title rawTitle: String, body rawBody: String,
        kind: WorkshopKind
    ) {
        guard let repoRoot else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else {
            show("A request needs a title or detail.", isError: true)
            return
        }
        guard title != request.title || body != request.body || kind != request.kind else {
            workshopEditor = nil
            return
        }
        do {
            try WorkshopLog.append(
                WorkshopEvent(
                    event: "edited", id: request.id,
                    fields: [
                    "title": .string(title),
                    "body": .string(body),
                    "kind": .string(kind.rawValue),
                    "by": .string("you"),
                ]),
                repoRoot: repoRoot)
            refreshBoard()
            selectedRequestID = request.id
            workshopEditor = nil
            show("Updated \(request.id).")
        } catch {
            show("Could not update the request: \(error.localizedDescription)", isError: true)
        }
    }

    /// Whether there is anything that can run the workshop agent.
    ///
    /// The in-house engine needs no `engine` at all — that is the whole point of it — so this
    /// cannot just test for one.
    var canRunWorkshopAgent: Bool { true }

    /// Which model the workshop agent runs on.
    ///
    /// It has no model of its own — this is the configured default, the same one the launcher
    /// offers. It used to name none at all, and `AgentCLI.resolve(nil)` means "the first model
    /// of the first provider in models.json", both sorted by id. On a machine whose first
    /// provider is a gateway that silently pinned the workshop agent to whatever sorted first
    /// there, ignoring the default set in Preferences — and, because the Models screen's test
    /// button defaults to that same first model, sending a test completion looked like it had
    /// *moved* the agent. Nothing had been written; the two defaults simply agreed.
    ///
    /// `nil` falls back to the old behaviour, which is right when the default names something
    /// this launcher cannot start. Both checks earn their place: the catalogue says the
    /// provider has working credentials, and `AgentCLI.resolve` is what `startInHouseRun`
    /// actually calls — it knows nothing about `claude-code`, which is a perfectly reachable
    /// default and not an in-house route.
    var workshopModelReference: String? {
        // An explicit choice wins over the global default. Stored as a qualified reference
        // rather than a ModelSpec because the catalogue is rebuilt on every launch and a
        // remembered object would be a stale copy of a row that may no longer exist.
        for candidate in [chosenWorkshopModel, settings.defaultModelQualified] {
            guard let qualified = candidate,
                  modelCatalog.find(qualified) != nil,
                  AgentCLI.resolve(qualified, in: modelsConfig) != nil
            else { continue }
            return qualified
        }
        return nil
    }

    /// The model the workshop agent is set to, whether or not it is currently startable.
    ///
    /// Kept separate from `workshopModelReference` so the UI can show a choice that has gone
    /// stale — a provider whose key was removed, a model dropped from the catalogue — instead
    /// of silently falling back and leaving the picker showing something that is not what runs.
    var chosenWorkshopModel: String? {
        get { UserDefaults.standard.string(forKey: "aviary.workshopModel") }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: "aviary.workshopModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "aviary.workshopModel")
            }
        }
    }

    /// What the workshop agent will actually start on, said in full.
    ///
    /// Engine-aware because the three engines take their model from three different places,
    /// and a card that named the in-house choice while the workshop was running on Claude Code
    /// would be a more confident version of the bug it exists to prevent.
    var workshopModelSummary: String {
        switch engineChoice {
        case .claudeCode:
            return "claude-code/\(claudeCodeModel) (set in the engine picker)"
        case .inHouse:
            guard let reference = workshopModelReference else {
                return "no startable model configured"
            }
            if let chosen = chosenWorkshopModel, chosen != reference {
                return "\(reference) — \(chosen) is set but will not start"
            }
            return reference + (chosenWorkshopModel == nil ? " (your default)" : "")
        }
    }

    /// Whether the model picker on this screen governs anything right now.
    var workshopModelIsSettableHere: Bool { engineChoice == .inHouse }

    /// Open or cold-reopen the workshop conversation on whichever engine is selected.
    ///
    /// One launcher for both entry points. They each used to build a harness
    /// `RunConfiguration` directly, which is why the workshop agent was always the harness even
    /// when the picker said otherwise — the last place that ignored the picker.
    private func startWorkshopRun(repoRoot: URL, resume: String?, firstPrompt: String?) {
        switch engineChoice {
        case .claudeCode:
            // The workshop's whole working method is one long-lived session it keeps returning
            // to, and a driven session cannot be resumed from Aviary's side — Claude Code owns
            // the history. So a driven workshop run is always a fresh session, and the
            // remembered id is left alone rather than being overwritten with one that the
            // in-house engine could not pick up either.
            startClaudeCodeRun(
                cwd: repoRoot.path, model: claudeCodeModel, effort: nil,
                prompt: firstPrompt ?? bootstrapPrompt(repoRoot: repoRoot), title: "Workshop")
        case .inHouse:
            startInHouseRun(
                cwd: repoRoot.path, providerID: nil, modelID: workshopModelReference,
                // An in-house run with no prompt prepares and waits, which is exactly what
                // attaching to an existing session wants.
                prompt: firstPrompt ?? "",
                resume: resume, title: "Workshop",
                onCreated: { [weak self] run in
                    self?.workshopRunID = run.id
                })
        }
        if engineChoice == .claudeCode {
            // Claude Code is still created synchronously by its process-owned path.
            workshopRunID = runs.last?.id
        }
    }

    /// Attach to the remembered workshop session without filing anything.
    func attachWorkshopSession() {
        guard let repoRoot, canRunWorkshopAgent else { return }
        if let run = workshopRun, !run.hasExited {
            if detachedRuns.contains(where: { $0.id == run.id }) {
                reattachRun(run)
            } else {
                focusedRunID = run.id
                section = .live
            }
            return
        }
        startWorkshopRun(
            repoRoot: repoRoot, resume: workshopSessionID,
            firstPrompt: workshopSessionID == nil ? bootstrapPrompt(repoRoot: repoRoot) : nil)
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                guard let self else { return }
                if let run = self.workshopRun, let sid = run.sessionID {
                    self.workshopSessionID = sid
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
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
        let live = workRuns.filter { !$0.hasExited }
        add("State", "Live runs", "\(live.count) (\(live.filter(\.isStreaming).count) working)")
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
            add("Cockpit", "Token count", Fmt.tokens(analytics.total))
        case .sessions:
            add("Sessions", "Showing", "\(filteredSessions.count) of \(sessions.count)")
            if let s = selectedSession {
                add("Selected session", "Id", s.id)
                add("Selected session", "Title", s.title)
                add("Selected session", "Project", s.projectName)
                add("Selected session", "Working dir", s.cwd)
                add(
                    "Selected session", "Model",
                    [s.provider, s.model].compactMap { $0 }.joined(separator: "/"))
                add(
                    "Selected session", "Live",
                    s.isLive ? (s.isBusy ? "yes, working" : "yes, idle") : "no")
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
                add(
                    "Focused run", "Exited",
                    run.hasExited ? "yes (code \(run.exitCode.map(String.init) ?? "?"))" : "no")
                add("Focused run", "Transcript rows", "\(run.items.count)")
                add("Focused run", "Session id", run.sessionID ?? "not yet assigned")
                add("Focused run", "Working dir", run.config.cwd)
                if let e = run.errorBanner { add("Focused run", "Error banner", e) }
                if let c = run.contextTokens {
                    add(
                        "Focused run", "Context",
                        "\(Fmt.tokens(c)) of \(run.contextWindow.map(Fmt.tokens) ?? "?")")
                }
            } else {
                add("Live", "Attached runs", "none")
            }
        case .workshop:
            add(
                "Workshop", "Board",
                "\(board.openCount) open · \(board.workingCount) in progress · \(board.doneCount) done"
            )
            add("Workshop", "Agent", workshopSessionState.label)
            if let s = selectedRequest { add("Workshop", "Selected request", s.id) }
        case .flock:
            add("Flock", "Nodes", "\(tree.allNodes.count)")
            add("Flock", "Running", "\(tree.runningCount)")
        case .models:
            add("Models", "Reachable", "\(runtimeModels.count)")
            add("Models", "Configured providers", "\(modelsConfig.providers.count)")
            let failed = providerTests.filter { !$0.value.ok }.keys.sorted()
            if !failed.isEmpty {
                add("Models", "Failing provider tests", failed.joined(separator: ", "))
            }
        case .usage:
            add("Usage", "Sessions counted", "\(analytics.sessionCount)")
            add("Usage", "Token count", Fmt.tokens(analytics.total))
        case .library:
            add("Library", "Skills", "\(library.skills.count)")
            add("Library", "Prompts", "\(library.prompts.count)")
            add("Library", "Extensions", "\(library.extensions.count)")
        case .health:
            for probe in runtimeProbes {
                add("Health", "Runtime \(probe.variant)", probe.summary)
            }
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
        case .cockpit: return "\(workRuns.filter { !$0.hasExited }.count) ongoing"
        case .sessions:
            let archived = sessions.filter(\.isArchived).count
            return "\(sessions.count - archived) current · \(archived) archived"
        case .live: return "\(runs.count) attached · \(detachedRuns.count) detached"
        case .workshop: return "\(board.openCount) open · \(board.requests.count) total"
        case .flock: return "\(tree.allNodes.count) sub-agents"
        case .models: return "\(runtimeModels.count) reachable"
        case .usage: return Fmt.tokens(analytics.total) + " tokens"
        case .library: return "\(library.skills.count) skills"
        case .health: return runtimeProbes.contains(where: \.ok) ? "ready" : "runtime unavailable"
        }
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return [v, b.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            .isEmpty
            ? "development build"
            : [v, b.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
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

// MARK: - Reloading Aviary after the workshop changes Aviary

extension AppModel {

    /// What a relaunch has to put back, and how long a note about it stays valid.
    ///
    /// A restart that dumps you on the Cockpit is a restart; one that comes back on the
    /// request you were watching, with the agent re-attached, is a reload. The whole
    /// difference between the two is written down here.
    private enum Restore {
        static let section = "aviary.reload.restore.section"
        static let request = "aviary.reload.restore.request"
        static let attach = "aviary.reload.restore.attach"
        static let stamp = "aviary.reload.restore.stamp"
        /// Beyond this, a stored position is somebody's old session rather than the reload
        /// that just happened, and restoring it would be a surprise.
        static let validFor: TimeInterval = 180
    }

    /// What relaunching now would cost, or nil when it costs nothing.
    ///
    /// Named rather than prevented. Right after the workshop agent finishes, the session that
    /// finished it is usually still attached and holding a live interpreter — and that is
    /// exactly the moment you want to reload. So the price is stated and the choice is yours.
    var reloadCost: String? {
        let processOwned = workRuns.filter { !$0.isServiceBacked }
        let streaming = processOwned.filter { $0.isStreaming && !$0.hasExited }
        let retained = processOwned.filter { !$0.hasExited }
        let serviceCount = workRuns.filter { $0.isServiceBacked && !$0.hasExited }.count
        if !streaming.isEmpty {
            let processMessage =
                "\(streaming.count) process-owned run\(streaming.count == 1 ? "" : "s") still working — "
                    + "relaunching stops \(streaming.count == 1 ? "it" : "them") mid-turn"
            if serviceCount > 0 {
                return processMessage + "; \(serviceCount) Work Host run\(serviceCount == 1 ? "" : "s") remain durable and will be reattached"
            }
            return processMessage
        }
        if !retained.isEmpty {
            let processMessage =
                "\(retained.count) process-owned run\(retained.count == 1 ? "" : "s") will end; "
                    + "the transcript survives, the interpreter's variables do not"
            if serviceCount > 0 {
                return processMessage + "; \(serviceCount) Work Host run\(serviceCount == 1 ? "" : "s") remain durable and will be reattached"
            }
            return processMessage
        }
        if serviceCount > 0 {
            return "\(serviceCount) Work Host run\(serviceCount == 1 ? "" : "s") remain durable and will be reattached after reload"
        }
        return nil
    }

    /// Write down where we are, then replace the process.
    func reloadNow() {
        guard !reloadInProgress else { return }
        reloadInProgress = true
        Task { await reloadAfterStoppingWork() }
    }

    /// Relaunch only after every in-process Work object has reached its teardown boundary.
    /// `Reloader.relaunch` terminates the application synchronously, so launching detached
    /// cleanup tasks here would orphan exactly the runtime children this path promises to end.
    private func reloadAfterStoppingWork() async {
        guard await stopAllWork() else {
            reloadInProgress = false
            acceptsNewWork = true
            toast = Toast(
                message: "Reload was canceled because an unsent draft is not durable. "
                    + "Copy or repair the marked draft, then try again.",
                isError: true)
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(section.rawValue, forKey: Restore.section)
        defaults.set(selectedRequestID, forKey: Restore.request)
        // Re-attach on the way back only if a workshop run was attached here — otherwise a
        // reload would silently start an agent session you never asked for.
        defaults.set(workshopRun != nil, forKey: Restore.attach)
        defaults.set(Date().timeIntervalSince1970, forKey: Restore.stamp)

        if !reloader.relaunch() {
            reloadInProgress = false
            await resumeAfterFailedRelaunch()
            toast = Toast(
                message: "Could not work out how to relaunch this copy of Aviary. "
                    + "Rebuild with `just build` and reopen.",
                isError: true)
        }
    }

    /// Come back where we were, if we got here by reloading.
    func restoreAfterReload() {
        let defaults = UserDefaults.standard
        let stamp = defaults.double(forKey: Restore.stamp)
        guard stamp > 0 else { return }
        defer {
            // Cleared unconditionally, including when it was too old to use: a stored
            // position that survives its own expiry would fire on some unrelated launch days
            // later.
            for key in [Restore.section, Restore.request, Restore.attach, Restore.stamp] {
                defaults.removeObject(forKey: key)
            }
        }
        guard Date().timeIntervalSince1970 - stamp < Restore.validFor else { return }

        if let raw = defaults.string(forKey: Restore.section),
            let restored = Section(rawValue: raw)
        {
            section = restored
        }
        if let id = defaults.string(forKey: Restore.request) { selectedRequestID = id }
        let shouldAttach = defaults.bool(forKey: Restore.attach)
        toast = Toast(
            message: "Reloaded"
                + (shouldAttach ? " — reopening the workshop session in a new runtime" : ""))
        guard shouldAttach, workshopSessionID != nil else { return }
        // After the board and engine list exist, cold continuation has what it needs to start.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            attachWorkshopSession()
        }
    }
}
