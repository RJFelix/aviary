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

                Card("Running elsewhere", symbol: "eye",
                     accessory: AnyView(
                        Button {
                            Task { await model.refreshDaemon() }
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)))
                {
                    if model.liveSessions.isEmpty {
                        Text("The background service is holding no sessions.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.liveSessions) { s in
                                LiveSessionRow(session: s)
                                    .onTapGesture { model.openTranscript(sessionID: s.sessionID) }
                                    .contextMenu {
                                        Button("Open transcript") {
                                            model.openTranscript(sessionID: s.sessionID)
                                        }
                                        Button("Copy attach command") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(
                                                "prime-agent attach \(s.id)", forType: .string)
                                        }
                                    }
                                if s.id != model.liveSessions.last?.id { Divider().opacity(0.5) }
                            }
                        }
                    }
                }
            }
            .padding(Design.gutter)
        }
    }
}

// MARK: - Run pane

struct RunPane: View {
    @Environment(AppModel.self) private var model
    var run: LiveRun

    @State private var draft = ""
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

            if model.showInspector {
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

            Menu {
                Button("Compact context now") { Task { await run.compact() } }
                    .disabled(run.hasExited)
                Divider()
                modelMenu
                thinkingMenu
                Divider()
                Button("Copy launch command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.launchCommand, forType: .string)
                }
                if let file = run.sessionFile {
                    Button("Reveal transcript") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
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
    }

    @ViewBuilder
    private var modelMenu: some View {
        Menu("Switch model") {
            ForEach(groupedModels, id: \.0) { provider, models in
                Menu(provider) {
                    ForEach(models) { m in
                        Button(m.displayName) {
                            Task { await run.setModel(provider: provider, model: m.id) }
                        }
                    }
                }
            }
        }
        .disabled(run.hasExited || model.runtimeModels.isEmpty)
    }

    private var groupedModels: [(String, [ModelSpec])] {
        Dictionary(grouping: model.runtimeModels, by: \.providerID)
            .map { ($0.key, $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.0 < $1.0 }
    }

    @ViewBuilder
    private var thinkingMenu: some View {
        Menu("Thinking level") {
            ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                Button(level) { Task { await run.setThinking(level) } }
            }
        }
        .disabled(run.hasExited)
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
        }
        .background(.bar)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await run.send(text) }
    }
}

// MARK: - Launcher

struct LauncherSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var cwd = ""
    @State private var prompt = ""
    @State private var provider: String = ""
    @State private var modelID: String = ""
    @State private var thinking = "high"
    @State private var persistSession = true
    @State private var noContextFiles = false
    @State private var recordPayloads = false

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

                    Card("Model", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.runtimeModels.isEmpty {
                                Text(model.runtimeModelsError
                                    ?? "Asking the engine which models it can reach…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(model.runtimeModelsError == nil
                                        ? .secondary : Design.danger)
                            } else {
                                Picker("Provider", selection: $provider) {
                                    ForEach(providers, id: \.self) { Text($0).tag($0) }
                                }
                                .onChange(of: provider) { _, _ in
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

                    Card("Engine", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: Binding(
                                get: { model.preferInHouseEngine },
                                set: { model.preferInHouseEngine = $0 }))
                            {
                                Text("Harness (Prime Agent)").tag(false)
                                Text("In-house (Aviary)").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            Text(model.preferInHouseEngine
                                ? "Aviary's own agent loop, provider client and Python runtime "
                                    + "host. No harness process and no Node. Skills are ranked "
                                    + "against your prompt rather than all sent, and the "
                                    + "transcript is written in the same format so every other "
                                    + "screen still reads it. Follow-ups continue in the same "
                                    + "interpreter, so variables persist between prompts."
                                : "The vendored Prime Agent harness over its RPC protocol. "
                                    + "Supports follow-ups, steering and payload recording.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .controlSize(.small)
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
                            if EngineLocator.wireLogExtension() == nil {
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
                    if model.preferInHouseEngine {
                        model.startInHouseRun(
                            cwd: cwd.isEmpty ? model.defaultCwd : cwd,
                            providerID: provider.isEmpty ? nil : provider,
                            modelID: modelID.isEmpty ? nil : modelID,
                            prompt: prompt)
                        dismiss()
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
                    dismiss()
                } label: {
                    Label("Start run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.engine == nil && !model.preferInHouseEngine)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            if cwd.isEmpty { cwd = model.defaultCwd }
            if provider.isEmpty {
                provider = model.settings.defaultProvider ?? providers.first ?? ""
            }
            if modelID.isEmpty {
                modelID = model.settings.defaultModel ?? modelsForProvider.first?.id ?? ""
            }
            thinking = model.settings.defaultThinkingLevel ?? "high"
        }
    }

    private var providers: [String] {
        Array(Set(model.runtimeModels.map(\.providerID))).sorted()
    }

    private var modelsForProvider: [ModelSpec] {
        model.runtimeModels.filter { $0.providerID == provider }.sorted { $0.id < $1.id }
    }

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
