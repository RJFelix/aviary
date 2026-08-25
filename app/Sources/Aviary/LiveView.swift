import SwiftUI
import AppKit
import Combine
import AviaryCore

/// Start runs, watch them stream, steer them mid-flight.
///
/// Two things share this screen deliberately: runs Aviary started (which it drives over the
/// harness's RPC protocol) and runs started anywhere else — a terminal, a cron schedule,
/// another agent. The second kind can only be observed, not steered, and the UI says so
/// rather than offering controls that would quietly do nothing.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var showLauncher = false

    var body: some View {
        Group {
            if let run = model.focusedRun {
                VStack(spacing: 0) {
                    if model.runs.count > 1 { runTabs }
                    RunPane(run: run)
                }
            } else {
                launcherLanding
            }
        }
        .sheet(isPresented: $showLauncher) { LauncherSheet() }
        .onNotification(.aviaryNewRun) { showLauncher = true }
    }

    private var runTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.runs) { run in
                    Button {
                        model.focusedRunID = run.id
                    } label: {
                        HStack(spacing: 5) {
                            if run.isStreaming {
                                PulseDot(color: Design.success)
                            } else if run.hasExited {
                                Image(systemName: "stop.circle").font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(run.title).font(.system(size: 11)).lineLimit(1)
                            Button {
                                model.closeRun(run)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(model.focusedRun?.id == run.id
                                ? Design.accentSoft : Color.secondary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 240)
                }
                Button {
                    showLauncher = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Design.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var launcherLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card("Start a run", symbol: "play.circle.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Aviary launches the engine in RPC mode and drives it directly — "
                            + "no terminal, and with your login shell's environment so "
                            + "credentials resolve the way they do in a terminal.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            showLauncher = true
                        } label: {
                            Label("New run…", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("n")
                    }
                }

                // `RunningElsewhereCard` is deliberately not shown — it lists sessions the
                // harness daemon is holding, and the in-house engine holds its runs itself
                // (they are right here on this screen). Retired rather than deleted; see
                // docs/architecture.md, "Retired daemon surfaces".
            }
            .padding(Design.gutter)
        }
    }
}

// MARK: - Run pane

struct RunPane: View {
    @Environment(AppModel.self) private var model
    var run: LiveRun
    /// Cockpit owns its two-column layout, so it reuses the chat/composer without a third
    /// technical column. Live keeps the detailed inspector.
    var showsInspector = true

    @State private var draft = ""
    @State private var showMarkdownPreview = true
    @State private var showLaunchDetails = false
    @State private var selectedItem: TranscriptItem?

    // Fixed trailing inspector column rather than `.inspector` or a conditional split
    // pane — see the note on SessionsView.body for why both of those misbehave.
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                runHeader
                Divider()
                if let banner = run.errorBanner {
                    NoticeBanner(level: .danger, title: "The run could not start", message: banner)
                        .padding(Design.gutter)
                }
                TranscriptView(
                    items: run.items,
                    hideThinking: model.hideThinking,
                    isStreaming: run.isStreaming,
                    autoScroll: true,
                    onSelect: { selectedItem = $0 })
                Divider()
                composer
            }
            .frame(minWidth: 380)

            if showsInspector && model.showInspector {
                Divider()
                RunInspector(run: run, selectedItem: $selectedItem)
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var runHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if run.isStreaming {
                    PulseDot()
                } else if run.hasExited {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    Circle().fill(Design.accent.opacity(0.7)).frame(width: 7, height: 7)
                }
                Text(run.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                if run.isCompacting { Chip(text: "compacting", tint: Design.warning) }
                if run.hasExited {
                    Chip(text: run.exitCode.map { "exited \($0)" } ?? "exited",
                         tint: (run.exitCode ?? 0) == 0 ? .secondary : Design.danger)
                }
                Spacer()
                controls
            }

            HStack(spacing: 5) {
                Chip(text: run.projectName, symbol: "folder", tint: Design.accent)
                    .help(run.config.cwd)
                if let m = run.modelLabel, !m.isEmpty {
                    Chip(text: m, symbol: "cpu", tint: Design.assistant)
                }
                if let level = run.thinkingLevel {
                    Chip(text: level, symbol: "brain", tint: Design.thinking)
                }
                if !run.usage.isEmpty {
                    Chip(text: Fmt.tokens(run.usage.totalTokens), symbol: "number", tint: .secondary)
                }
                if run.usage.cost.total > 0 {
                    Chip(text: Fmt.cost(run.usage.cost.total), tint: Design.accent)
                }
                Chip(text: Fmt.duration(run.elapsed), symbol: "clock", tint: .secondary)
                Spacer()
                if let share = run.contextShare, let tokens = run.contextTokens {
                    HStack(spacing: 5) {
                        Text("context")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        RatioBar(
                            fraction: share,
                            tint: share > 0.85 ? Design.danger
                                : share > 0.65 ? Design.warning : Design.accent)
                            .frame(width: 90)
                        Text("\(Fmt.tokens(tokens)) / \(Fmt.tokens(run.contextWindow ?? 0))")
                            .font(Design.numeric(9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !run.queuedSteering.isEmpty || !run.queuedFollowUps.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 9)).foregroundStyle(Design.warning)
                    Text(queueSummary)
                        .font(.system(size: 10.5)).foregroundStyle(Design.warning)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, Design.gutter)
        .padding(.vertical, 9)
        .background(.background.secondary)
    }

    private var queueSummary: String {
        var parts: [String] = []
        if !run.queuedSteering.isEmpty {
            parts.append("\(run.queuedSteering.count) steering")
        }
        if !run.queuedFollowUps.isEmpty {
            parts.append("\(run.queuedFollowUps.count) follow-up")
        }
        return "Queued: " + parts.joined(separator: ", ")
            + " — delivered after the current turn's tool calls finish"
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if run.isStreaming {
                Button {
                    run.abort()
                } label: {
                    Label("Abort", systemImage: "stop.fill").font(.system(size: 10.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Design.danger)
            }

            RunOptionsMenu(
                run: run,
                models: model.pickerModels,
                hasExited: run.hasExited,
                sessionFile: run.sessionFile)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(run.isStreaming
                            ? "Steer the run — lands after the current tool calls…"
                            : "Ask for something…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 34, maxHeight: 130)
                        .padding(.horizontal, 1)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1))

                VStack(spacing: 5) {
                    Button { showMarkdownPreview.toggle() } label: {
                        Image(systemName: showMarkdownPreview ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                            .frame(width: 26, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .disabled(draft.isEmpty)
                    .help(showMarkdownPreview ? "Hide Markdown preview" : "Show Markdown preview")

                    Button {
                        send()
                    } label: {
                        Image(systemName: run.isStreaming ? "arrow.turn.down.right" : "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(run.hasExited || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(run.isStreaming
                        ? "Steer (⌘↵) — delivered before the next model call"
                        : "Send (⌘↵)")

                    Button {
                        let text = draft
                        draft = ""
                        Task { await run.queueFollowUp(text) }
                    } label: {
                        Image(systemName: "text.append")
                            .font(.system(size: 10))
                            .frame(width: 26, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .disabled(run.hasExited || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Queue as a follow-up — delivered only once the agent stops")
                }
            }
            .padding(.horizontal, Design.gutter)
            .padding(.vertical, 9)

            if showMarkdownPreview, !draft.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("MARKDOWN PREVIEW")
                        .font(Design.sectionTitle).foregroundStyle(.secondary)
                    ScrollView {
                        MarkdownText(text: draft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }
                .padding(.horizontal, Design.gutter)
                .padding(.vertical, 9)
                .background(.background.secondary)
            }
        }
        .background(.bar)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await run.send(text) }
    }
}

/// The run's menu, in a view of its own so that an open submenu survives the run streaming.
///
/// Not tidiness. `LiveRun` is `@Observable`, and the in-house and driven engines both mirror
/// their driver onto it from a 250ms loop that assigns every field *unconditionally* — the
/// Observation setter notifies on every assignment whether or not the value changed, so an
/// idle run invalidates `RunPane` four times a second forever. `RunPane` reads five of the
/// mirrored fields (`items`, `isStreaming`, `hasExited`, `usage`, `errorBanner`), so while the
/// menu lived in that body its content was rebuilt at 4Hz, and AppKit answers a rebuilt
/// NSMenu by tearing down and re-presenting whichever submenu is open. Hovering "Switch
/// model" flashed a submenu nothing could be clicked in.
///
/// So everything the menu *draws* arrives as a value and the comparison below decides when it
/// is redrawn. The `run` is held for its actions only: reading an observable property of it in
/// this body would re-open the same hole, and `launchCommand` is read inside a button's action
/// rather than beside it for exactly that reason — observation tracks what a body reads, not
/// what a closure will read later. The poll loop in `AppModel.startPolling` is not implicated;
/// it touches daemon state this screen never reads.
/// The run's overflow menu, taking values rather than observing the run.
///
/// It was briefly wrapped in `EquatableView` to stop it being rebuilt. That did not work and
/// made things worse — the root row lost its highlight as well as the submenu — because the
/// invalidation was upstream: `LiveRun`'s mirror re-published its state every 250ms whether or
/// not anything had changed, so the parent re-rendered regardless of what this view compared
/// equal to. The fix belongs there, and the shield is gone rather than left as cargo.
struct RunOptionsMenu: View {
    @Environment(AppModel.self) private var model
    var run: LiveRun
    var models: [ModelSpec]
    var hasExited: Bool
    var sessionFile: String?

    var body: some View {
        Menu {
            Button("Compact context now") { Task { await run.compact() } }
                .disabled(hasExited)
            Divider()
            modelMenu
            thinkingMenu
            Divider()
            Button("Copy launch command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.launchCommand, forType: .string)
            }
            if let sessionFile {
                Button("Reveal transcript") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: sessionFile)])
                }
            }
            Divider()
            Button("Close run", role: .destructive) { model.closeRun(run) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var modelMenu: some View {
        Menu("Switch model") {
            ForEach(groupedModels, id: \.0) { provider, models in
                Menu(provider) {
                    ForEach(models) { m in
                        Button(m.displayName) {
                            Task { await model.switchModel(
                                run: run, provider: provider, model: m.id) }
                        }
                    }
                }
            }
        }
        .disabled(hasExited || models.isEmpty)
    }

    /// Grouped for the switcher, in your order rather than alphabetically.
    ///
    /// Providers are ordered by where their first model sits, so pinning a model to the top
    /// brings its provider with it instead of leaving the group buried under `a`-something.
    private var groupedModels: [(String, [ModelSpec])] {
        var groups: [(String, [ModelSpec])] = []
        for m in models {
            if let i = groups.firstIndex(where: { $0.0 == m.providerID }) {
                groups[i].1.append(m)
            } else {
                groups.append((m.providerID, [m]))
            }
        }
        return groups
    }

    @ViewBuilder
    private var thinkingMenu: some View {
        Menu("Thinking level") {
            ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                Button(level) { Task { await run.setThinking(level) } }
            }
        }
        .disabled(hasExited)
    }
}

// MARK: - Launcher

struct LauncherSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("New run", systemImage: "play.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            LauncherFormBody(onStart: { dismiss() })
        }
        .frame(width: 560, height: 640)
    }
}

/// The launcher's cards and start action, shared by the modal (`LauncherSheet`, used from Live)
/// and Cockpit's inline composer (`NewSessionPane`). Same options either way — a run does not
/// need fewer of them just because it was started from a card instead of a sheet — so the form
/// lives once and each caller supplies its own chrome and its own `onStart`.
struct LauncherFormBody: View {
    @Environment(AppModel.self) private var model
    var onStart: () -> Void

    @State private var cwd = ""
    @State private var prompt = ""
    @State private var provider: String = ""
    @State private var modelID: String = ""
    @State private var thinking = "high"
    /// Which engine to go back to when you leave `claude-code` behind. Remembered because
    /// Harness and In-house are a real choice between themselves, and snapping to one of them
    /// arbitrarily would silently change what a run is.
    @State private var lastDirectEngine: AppModel.Engine = .inHouse
    @State private var persistSession = true
    @State private var noContextFiles = false
    @State private var recordPayloads = false


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card("Working directory", symbol: "folder") {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                TextField("", text: $cwd)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Design.mono(11))
                                Button("Choose…") { chooseDirectory() }
                                    .controlSize(.small)
                            }
                            if !model.recentCwds.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        ForEach(model.recentCwds, id: \.self) { path in
                                            Button {
                                                cwd = path
                                            } label: {
                                                Chip(
                                                    text: URL(fileURLWithPath: path).lastPathComponent,
                                                    symbol: "clock",
                                                    tint: cwd == path ? Design.accent : .secondary,
                                                    filled: cwd == path)
                                            }
                                            .buttonStyle(.plain)
                                            .help(path)
                                        }
                                    }
                                }
                            }
                            Text("The agent's AGENTS.md and CLAUDE.md discovery walks up from "
                                + "here, so this choice changes its instructions, not just its "
                                + "file paths.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Card("Engine", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: Binding(
                                get: { model.engineChoice },
                                set: { model.engineChoice = $0 }))
                            {
                                ForEach(AppModel.Engine.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            .onChange(of: model.engineChoice) { _, now in
                                if now != .claudeCode { lastDirectEngine = now }
                                // The engines offer disjoint catalogues, so a selection made
                                // under one is meaningless under the other. Re-seeded rather
                                // than left alone, because a picker showing a provider absent
                                // from its own list renders blank.
                                if !providers.contains(provider) {
                                    provider = providers.first ?? ""
                                }
                                if !modelsForProvider.contains(where: { $0.id == modelID }) {
                                    modelID = modelsForProvider.first?.id ?? ""
                                }
                            }
                            Text(engineExplanation)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if model.engineChoice == .claudeCode {
                                Divider().opacity(0.5)
                                if let auth = model.claudeCodeAuth {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(auth.isSubscription
                                                ? Design.success : Design.warning)
                                            .frame(width: 6, height: 6)
                                        Text(auth.isSubscription
                                            ? "\(auth.summary) — draws on the plan"
                                            : "\(auth.summary) — bills metered API credit")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("No `claude` binary found, or it is not signed in. "
                                        + "Install Claude Code and run `claude /login`.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Design.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .controlSize(.small)
                    }

                    Card("Model", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.pickerModels.isEmpty {
                                Text(model.runtimeModelsError
                                    ?? "Asking the engine which models it can reach…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(model.runtimeModelsError == nil
                                        ? .secondary : Design.danger)
                            } else {
                                Picker("Provider", selection: $provider) {
                                    ForEach(providers, id: \.self) { Text($0).tag($0) }
                                }
                                .onChange(of: provider) { _, now in
                                    // Picking the provider sets the engine, because for this
                                    // one they are the same fact: Claude Code *is* the thing
                                    // that answers, so choosing it as a provider is choosing
                                    // it as the engine. Making you say it twice — once here
                                    // and once in the segment above — is what sent somebody
                                    // hunting through the provider list for a route that was
                                    // gated behind a control they had not touched.
                                    if now == "claude-code" {
                                        model.engineChoice = .claudeCode
                                    } else if model.engineChoice == .claudeCode {
                                        model.engineChoice = lastDirectEngine
                                    }
                                    modelID = modelsForProvider.first?.id ?? ""
                                }
                                Picker("Model", selection: $modelID) {
                                    ForEach(modelsForProvider) { m in
                                        Text(m.displayName).tag(m.id)
                                    }
                                }
                                if let selected = modelsForProvider.first(where: { $0.id == modelID }) {
                                    ModelFactsRow(model: selected, requestedThinking: thinking)
                                }
                            }
                            Picker("Thinking", selection: $thinking) {
                                ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"],
                                        id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }

                    Card("First prompt", symbol: "text.cursor") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $prompt)
                                .font(.system(size: 12.5))
                                .frame(minHeight: 90)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(.separator, lineWidth: 1))
                            Text("Optional — you can start empty and type into the run.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }

                    Card("Options", symbol: "slider.horizontal.3") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Save the session to disk", isOn: $persistSession)
                            Toggle("Skip AGENTS.md / CLAUDE.md discovery", isOn: $noContextFiles)
                            Divider().opacity(0.5)
                            Toggle("Record what's sent to the model", isOn: $recordPayloads)
                            Text("Captures every provider request — system prompt, context "
                                + "files, skill catalogue, tool schemas, messages — so the run "
                                + "can show where its input tokens went. Writes them to a file "
                                + "in Aviary's support directory, which is why it is off by "
                                + "default.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            if model.preferInHouseEngine {
                                Text("On the in-house engine this is native — the provider "
                                    + "announces each payload as it sends it, so there is no "
                                    + "extension to install.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            } else if EngineLocator.wireLogExtension() == nil {
                                Text("Unavailable: harness-extensions/wire-log.ts is missing "
                                    + "from this checkout.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Design.warning)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                if let engine = model.engine {
                    Text("\(engine.kind.label) · \(engine.version ?? "?")")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    if model.engineChoice == .claudeCode {
                        model.startClaudeCodeRun(
                            cwd: cwd.isEmpty ? model.defaultCwd : cwd,
                            // From the Model card, like every other engine. `claudeCodeModel`
                            // is still where the choice is remembered between runs, which is
                            // why it is written here rather than read.
                            model: modelID.isEmpty ? model.claudeCodeModel : modelID,
                            // "off" is the picker's no-reasoning value; Claude Code has no such
                            // level, so it is expressed by omitting the flag entirely.
                            effort: thinking == "off" ? nil : thinking,
                            prompt: prompt)
                        onStart()
                        return
                    }
                    if model.engineChoice == .inHouse {
                        model.startInHouseRun(
                            cwd: cwd.isEmpty ? model.defaultCwd : cwd,
                            providerID: provider.isEmpty ? nil : provider,
                            modelID: modelID.isEmpty ? nil : modelID,
                            prompt: prompt,
                            recordPayloads: recordPayloads)
                        onStart()
                        return
                    }
                    model.startRun(
                        config: RunConfiguration(
                            cwd: cwd.isEmpty ? model.defaultCwd : cwd,
                            provider: provider.isEmpty ? nil : provider,
                            model: modelID.isEmpty ? nil : modelID,
                            thinkingLevel: thinking,
                            persistSession: persistSession,
                            noContextFiles: noContextFiles,
                            recordPayloads: recordPayloads
                                && EngineLocator.wireLogExtension() != nil),
                        firstPrompt: prompt.isEmpty ? nil : prompt)
                    onStart()
                } label: {
                    Label("Start run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.engine == nil && model.engineChoice == .harness)
            }
            .padding(14)
        }
        .onAppear {
            if cwd.isEmpty { cwd = model.defaultCwd }
            if model.engineChoice != .claudeCode { lastDirectEngine = model.engineChoice }
            // Seeded from the remembered engine, so reopening the sheet after a driven run
            // does not show `litellm` above an engine segment that says Claude Code. The
            // defaults in settings describe a provider route and cannot express this one.
            if model.engineChoice == .claudeCode {
                provider = "claude-code"
                if !modelsForProvider.contains(where: { $0.id == modelID }) {
                    modelID = model.claudeCodeModel
                }
            } else {
                if provider.isEmpty || provider == "claude-code" {
                    provider = model.settings.defaultProvider ?? providers.first ?? ""
                }
                if modelID.isEmpty
                    || !modelsForProvider.contains(where: { $0.id == modelID }) {
                    modelID = model.settings.defaultModel ?? modelsForProvider.first?.id ?? ""
                }
            }
            thinking = model.settings.defaultThinkingLevel ?? "high"
        }
    }


    /// What each engine actually is, in the terms that matter when choosing one.
    ///
    /// The third entry is a different kind of thing from the first two and the text says so:
    /// the first two are Aviary's loop over a provider, and the third is somebody else's loop
    /// over Aviary's kernel. Hiding that behind a neutral label would make the picker lie.
    private var engineExplanation: String {
        switch model.engineChoice {
        case .inHouse:
            return "Aviary's own agent loop, provider client and Python runtime host. No "
                + "harness process and no Node. Skills are ranked against your prompt rather "
                + "than all sent, and the transcript is written in the same format so every "
                + "other screen still reads it. Follow-ups continue in the same interpreter, "
                + "so variables persist between prompts. Steering, payload recording and "
                + "resuming a session all work."
        case .harness:
            return "The vendored Prime Agent harness over its RPC protocol. Still the "
                + "default, and still what the daemon and kernel list are read from."
        case .claudeCode:
            return "Claude Code drives, and Aviary's kernel is the only tool it gets — its "
                + "loop, its history, its stopping decision; your interpreter, your skills, "
                + "your memory. Tokens come out of the Claude plan rather than metered API "
                + "credit, which is the point. What you give up: steering, sub-agents, model "
                + "switching mid-run, and resuming an Aviary session, because the "
                + "conversation belongs to Claude Code and it will not accept a prepared one."
        }
    }

    /// In catalogue order, de-duplicated by first appearance, so the picker agrees with the
    /// switcher and both follow your ordering.
    private var providers: [String] {
        var seen = Set<String>()
        return offeredModels.compactMap {
            seen.insert($0.providerID).inserted ? $0.providerID : nil
        }
    }

    private var modelsForProvider: [ModelSpec] {
        offeredModels.filter { $0.providerID == provider }
    }

    /// Every reachable route, `claude-code` included, whichever engine is selected.
    ///
    /// It is deliberately *not* filtered by engine. Filtering was the first attempt and it was
    /// wrong in a way that only shows up in use: `claude-code` was absent from the provider
    /// list until you had already found the Engine segment and switched it, so somebody looking
    /// for "Claude Code plus a Claude model" in the obvious place found four providers and
    /// concluded the feature was missing.
    ///
    /// Picking it instead *sets* the engine — see the provider picker's `onChange`. The two
    /// controls stay in step in both directions, and the engine segment remains because
    /// Harness versus In-house is a real choice that no model selection expresses.
    private var offeredModels: [ModelSpec] { model.pickerModels }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: cwd.isEmpty ? model.defaultCwd : cwd)
        if panel.runModal() == .OK, let url = panel.url { cwd = url.path }
    }
}

/// The facts about a model that change how you'd use it, including the ones that are
/// easy to be wrong about.
struct ModelFactsRow: View {
    var model: ModelSpec
    var requestedThinking: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let w = model.contextWindow {
                    Chip(text: "\(Fmt.tokens(w)) ctx", tint: .secondary)
                }
                if let m = model.maxTokens {
                    Chip(text: "\(Fmt.tokens(m)) out", tint: .secondary)
                }
                if model.reasoning { Chip(text: "reasoning", symbol: "brain", tint: Design.thinking) }
                if model.supportsImages { Chip(text: "images", symbol: "photo", tint: .secondary) }
                if let i = model.costInput, let o = model.costOutput {
                    Chip(text: "$\(fmt(i))/$\(fmt(o))", tint: Design.accent)
                        .help("per million tokens, input / output")
                }
            }
            // A thinking level that the provider maps to null does not reach the model at
            // all. That is silent in the harness and expensive to discover by experiment.
            if let requested = requestedThinking,
               model.deadThinkingLevels.contains(requested)
            {
                Text("This provider maps “\(requested)” to nothing — the request would carry "
                    + "no reasoning effort. Levels that do map through: "
                    + mappedLevels.joined(separator: ", ") + ".")
                    .font(.system(size: 10))
                    .foregroundStyle(Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mappedLevels: [String] {
        guard let map = model.thinkingLevelMap else { return ["all"] }
        return map.filter { $0.value != nil }.keys.sorted()
    }

    private func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
    }
}

// MARK: - Run inspector

struct RunInspector: View {
    var run: LiveRun
    @Binding var selectedItem: TranscriptItem?
    @State private var showBreakdown = false
    @State private var showRaw = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card("Run", symbol: "info.circle") {
                    VStack(alignment: .leading, spacing: 5) {
                        DetailRow(label: "Started", value: Fmt.timestamp(run.startedAt))
                        DetailRow(label: "Elapsed", value: Fmt.duration(run.elapsed))
                        DetailRow(label: "Working dir", value: run.config.cwd, mono: true)
                        if let id = run.sessionID {
                            DetailRow(label: "Session id", value: id, mono: true)
                        }
                        DetailRow(label: "Model", value: run.modelLabel ?? "—", mono: true)
                        DetailRow(label: "Thinking", value: run.thinkingLevel ?? "—")
                        DetailRow(
                            label: "Session saved",
                            value: run.config.persistSession ? "yes" : "no (--no-session)")
                    }
                }

                if let driver = run.inHouse {
                    ScheduleCard(driver: driver)
                }

                if let driver = run.claudeCode {
                    ClaudeCodeRunCard(driver: driver)
                }

                Card("Tokens", symbol: "number") {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            StatTile(label: "in", value: Fmt.tokens(run.usage.input))
                            StatTile(label: "out", value: Fmt.tokens(run.usage.output))
                            StatTile(label: "cached", value: Fmt.tokens(run.usage.cacheRead))
                        }
                        if run.usage.cost.total > 0 {
                            DetailRow(label: "Cost", value: Fmt.cost(run.usage.cost.total), mono: true)
                        }
                        if let rate = run.usage.cacheHitRate {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("cache hit rate").font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Fmt.percent(rate)).font(Design.numeric(10, weight: .semibold))
                                }
                                RatioBar(fraction: rate, tint: Design.tool)
                            }
                        }
                    }
                }

                if !run.queuedSteering.isEmpty || !run.queuedFollowUps.isEmpty {
                    Card("Queued", symbol: "tray.full") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(run.queuedSteering.enumerated()), id: \.offset) { _, m in
                                queueItem(m, label: "steer", tint: Design.warning)
                            }
                            ForEach(Array(run.queuedFollowUps.enumerated()), id: \.offset) { _, m in
                                queueItem(m, label: "follow-up", tint: Design.accent)
                            }
                        }
                    }
                }

                if !run.stderrTail.isEmpty {
                    Card("Engine stderr", symbol: "exclamationmark.bubble") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Where the useful failures land — a 401 naming an unresolved "
                                + "variable, a version-conflict refusal.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            CodeBlock(
                                text: run.stderrTail.suffix(30).joined(),
                                maxLines: 12, tint: Design.danger)
                        }
                    }
                }

                contextCard

                Card("Launch command", symbol: "terminal") {
                    CodeBlock(text: run.launchCommand, maxLines: 8, tint: .secondary)
                }
            }
            .padding(12)
        }
        .sheet(isPresented: $showBreakdown) {
            if let analysis = run.latestAnalysis {
                VStack(spacing: 0) {
                    HStack {
                        Text("What was sent to the model")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Done") { showBreakdown = false }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(12)
                    Divider()
                    ContextBreakdownView(
                        analysis: analysis,
                        actualInputTokens: run.lastInputTokens,
                        recordedAt: run.wireRecords.last(where: { $0.kind == .request })?.at)
                }
                .frame(width: 820, height: 720)
            }
        }
        .sheet(isPresented: $showRaw) {
            RawPayloadSheet(records: run.wireRecords)
        }
    }

    @ViewBuilder
    private var contextCard: some View {
        if run.config.recordPayloads {
            Card("What was sent", symbol: "arrow.up.doc",
                 accessory: AnyView(
                    HStack(spacing: 8) {
                        Button("Breakdown") { showBreakdown = true }
                            .buttonStyle(.link).font(.system(size: 10))
                            .disabled(run.latestAnalysis == nil)
                        Button("Raw") { showRaw = true }
                            .buttonStyle(.link).font(.system(size: 10))
                            .disabled(run.wireRecords.isEmpty)
                    }))
            {
                if let analysis = run.latestAnalysis {
                    VStack(alignment: .leading, spacing: 6) {
                        DetailRow(
                            label: "Payload",
                            value: "\(Fmt.bytes(analysis.totalCharacters)) · ≈\(Fmt.tokens(analysis.estimatedTokens)) tokens")
                        if let actual = run.lastInputTokens {
                            DetailRow(label: "Billed input", value: Fmt.tokens(actual), mono: true)
                        }
                        Divider().opacity(0.5)
                        // The three or four biggest parts answer the question on their own.
                        ForEach(analysis.segments.prefix(4)) { seg in
                            HStack(spacing: 6) {
                                Text(seg.label)
                                    .font(.system(size: 10.5))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(String(format: "%.0f%%", 100 * seg.share(of: analysis.totalCharacters)))
                                    .font(Design.numeric(10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Recording is on. The first provider request will appear here.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func queueItem(_ text: String, label: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Chip(text: label, tint: tint)
            Text(text).font(.system(size: 10.5)).lineLimit(3)
            Spacer()
        }
    }
}

// MARK: - Notification helper

extension View {
    /// A small bridge from NotificationCenter to SwiftUI, for menu commands that need to
    /// reach a view rather than the model.
    func onNotification(_ name: Notification.Name, perform: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in perform() }
    }
}

// MARK: - Schedules

/// Work a session does on its own, and a way to add some.
///
/// Only shown for in-house runs, because only they have a scheduler. The harness's own cron
/// jobs are readable through `list --json` but not settable from here, and offering one control
/// that silently does nothing for half the runs would be worse than offering none.
private struct ScheduleCard: View {
    let driver: InHouseDriver
    @State private var prompt = ""
    @State private var minutes = 15.0
    @State private var whenIdle = true
    @State private var adding = false

    var body: some View {
        Card("On its own", symbol: "clock.arrow.2.circlepath",
             accessory: AnyView(
                Button {
                    adding.toggle()
                } label: {
                    Image(systemName: adding ? "xmark" : "plus").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)))
        {
            VStack(alignment: .leading, spacing: 7) {
                if driver.jobs.isEmpty && !adding {
                    Text("Nothing scheduled. This session can poke itself on an interval — "
                        + "useful for watching a build, or checking back on something slow.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(driver.jobs) { job in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: job.onlyWhenIdle ? "moon.zzz" : "clock")
                            .font(.system(size: 9)).foregroundStyle(Design.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.prompt)
                                .font(.system(size: 11)).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(job.summary)
                                .font(Design.numeric(9)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            driver.removeJob(id: job.id)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 8.5))
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                if adding {
                    Divider().opacity(0.5)
                    TextField("What should it ask?", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11)).lineLimit(1...3)
                    HStack(spacing: 6) {
                        Text("every")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        // Minutes, not a cron expression: every real case in the corpus was
                        // "every N minutes", and a cron parser is a class of bugs bought for a
                        // case nobody had.
                        Stepper("\(Int(minutes))m", value: $minutes, in: 1...240, step: 5)
                            .font(.system(size: 10))
                        Spacer(minLength: 4)
                        Toggle("only when idle", isOn: $whenIdle)
                            .toggleStyle(.checkbox).font(.system(size: 10))
                        Button("Add") {
                            driver.addJob(
                                prompt: prompt, everyMinutes: minutes, onlyWhenIdle: whenIdle)
                            prompt = ""
                            adding = false
                        }
                        .controlSize(.small)
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.mini)
                }
            }
        }
    }
}

/// What is only true of a driven run.
///
/// Two facts earn a card of their own. Which allowance the run is spending is the entire
/// economic premise of this session type, and it comes from Claude Code rather than from
/// anything Aviary can compute — so it is reported, never inferred. And Claude Code's own
/// session id is what `claude --resume` takes, which is the only way to reopen this
/// conversation with its history intact.
private struct ClaudeCodeRunCard: View {
    var driver: ClaudeCodeDriver

    var body: some View {
        Card("Claude Code", symbol: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 7) {
                if let limit = driver.rateLimit {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(limit.usingOverage ? Design.warning : Design.success)
                            .frame(width: 6, height: 6)
                        Text(limit.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(limit.usingOverage ? Design.warning : .secondary)
                        Spacer()
                        if let resets = limit.resetsAt {
                            Text("resets \(Fmt.relative(resets))")
                                .font(Design.numeric(10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                if let auth = driver.authSummary {
                    DetailRow(label: "Login", value: auth)
                }
                if let id = driver.claudeSessionID {
                    DetailRow(label: "Claude session", value: id, mono: true)
                    Text("`claude --resume \(id)` reopens this conversation in Claude Code "
                        + "itself, with the history Aviary cannot replay.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let runtime = driver.runtimeSummary {
                    DetailRow(label: "Kernel", value: runtime, mono: true)
                }
                if let skills = driver.skillsNote {
                    DetailRow(label: "Skills", value: skills)
                }
                if let memory = driver.memoryNote {
                    DetailRow(label: "Memory", value: memory)
                }
                ForEach(Array(driver.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(Design.warning)
                        Text(warning)
                            .font(.system(size: 10)).foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
