import SwiftUI
import AppKit
import AviaryCore

/// Aviary's own settings, plus in-place edits to the harness's `settings.json`.
///
/// The harness defaults live in its file, not in Aviary's preferences — writing them
/// anywhere else would mean the GUI and the CLI disagreed about what "default model"
/// means, which is exactly the sort of split-brain this app exists to prevent.
struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @State private var customEnginePath = UserDefaults.standard
        .string(forKey: "aviary.customEnginePath") ?? ""
    @State private var saving = false

    var body: some View {
        TabView {
            engineTab
                .tabItem { Label("Engine", systemImage: "cpu") }
            defaultsTab
                .tabItem { Label("Agent defaults", systemImage: "slider.horizontal.3") }
            appearanceTab
                .tabItem { Label("Display", systemImage: "eye") }
            workshopTab
                .tabItem { Label("Workshop", systemImage: "wrench.and.screwdriver") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
    }

    // MARK: Engine

    private var engineTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card("Active engine", symbol: "cpu") {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.engines.isEmpty {
                            Text("No engine found.").font(.system(size: 11.5))
                                .foregroundStyle(Design.danger)
                        }
                        ForEach(model.engines) { e in
                            HStack(spacing: 8) {
                                Image(systemName: model.engine == e
                                    ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(model.engine == e ? Design.accent : .secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("\(e.kind.label) · \(e.version ?? "?")")
                                        .font(.system(size: 11.5, weight: .medium))
                                    Text(e.displayPath).font(Design.mono(9.5))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.engine = e }
                        }
                    }
                }

                Card("Custom engine path", symbol: "folder.badge.gearshape") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("An explicit executable to use instead of the discovered ones. "
                            + "Takes effect after a relaunch.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 7) {
                            TextField("/path/to/prime-agent", text: $customEnginePath)
                                .textFieldStyle(.roundedBorder).font(Design.mono(11))
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = true
                                panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    customEnginePath = url.path
                                }
                            }
                            .controlSize(.small)
                            Button("Save") {
                                UserDefaults.standard.set(
                                    customEnginePath, forKey: "aviary.customEnginePath")
                                model.show("Saved — relaunch Aviary to pick it up")
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Card("Agent directory", symbol: "folder") {
                    VStack(alignment: .leading, spacing: 5) {
                        DetailRow(label: "Root", value: model.home.root.path, mono: true)
                        DetailRow(
                            label: "Exists",
                            value: model.home.exists ? "yes" : "no",
                            tint: model.home.exists ? nil : Design.danger)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.home.root])
                        }
                        .buttonStyle(.link).font(.system(size: 10.5))
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Agent defaults

    private var defaultsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card("Written to Aviary's settings.json", symbol: "doc.badge.gearshape") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("These defaults are shared with Aviary's command-line agent. "
                            + "Aviary edits the file in place and preserves every key it does "
                            + "not manage.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        DetailRow(
                            label: "Default model",
                            value: model.settings.defaultModelQualified ?? "not set", mono: true)
                        DetailRow(
                            label: "Thinking level",
                            value: model.settings.defaultThinkingLevel ?? "not set")
                        DetailRow(label: "Packages", value: "\(model.settings.packages.count)")

                        Divider().opacity(0.5)

                        Text("SET THE DEFAULT MODEL")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        if model.runtimeModels.isEmpty {
                            Text("Waiting for the engine's model catalog…")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(model.runtimeModels.sorted(by: {
                                        ($0.providerID, $0.id) < ($1.providerID, $1.id)
                                    })) { m in
                                        Button {
                                            setDefault(model: m)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: isDefault(m)
                                                    ? "largecircle.fill.circle" : "circle")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(isDefault(m)
                                                        ? Design.accent : .secondary)
                                                Text(m.qualifiedID).font(Design.mono(10.5))
                                                Spacer()
                                                if m.reasoning {
                                                    Image(systemName: "brain")
                                                        .font(.system(size: 8))
                                                        .foregroundStyle(Design.thinking)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 160)
                        }

                        Divider().opacity(0.5)

                        Picker("Thinking level", selection: Binding(
                            get: { model.settings.defaultThinkingLevel ?? "high" },
                            set: { setThinking($0) }))
                        {
                            ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"],
                                    id: \.self) { Text($0).tag($0) }
                        }
                        .controlSize(.small)

                        Button("Open settings.json") {
                            NSWorkspace.shared.open(model.settings.fileURL)
                        }
                        .buttonStyle(.link).font(.system(size: 10.5))
                    }
                }
            }
            .padding(14)
        }
    }

    private func isDefault(_ m: ModelSpec) -> Bool {
        model.settings.defaultProvider == m.providerID && model.settings.defaultModel == m.id
    }

    private func setDefault(model m: ModelSpec) {
        do {
            try model.settings.write(key: "defaultProvider", value: .string(m.providerID))
            model.settings = .load(home: model.home)
            try model.settings.write(key: "defaultModel", value: .string(m.id))
            model.settings = .load(home: model.home)
            model.show("Default model set to \(m.qualifiedID)")
        } catch {
            model.show(error.localizedDescription, isError: true)
        }
    }

    private func setThinking(_ level: String) {
        do {
            try model.settings.write(key: "defaultThinkingLevel", value: .string(level))
            model.settings = .load(home: model.home)
        } catch {
            model.show(error.localizedDescription, isError: true)
        }
    }

    // MARK: Display

    private var appearanceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card("Transcript", symbol: "text.alignleft") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Hide thinking blocks by default", isOn: Binding(
                            get: { model.hideThinking },
                            set: { newValue in
                                model.hideThinking = newValue
                                try? model.settings.write(
                                    key: "hideThinkingBlock", value: .bool(newValue))
                                model.settings = .load(home: model.home)
                            }))
                        Text("Stored as `hideThinkingBlock` so historical and live readers agree.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        Divider().opacity(0.5)
                        Toggle("Show the inspector pane", isOn: Binding(
                            get: { model.showInspector },
                            set: { model.showInspector = $0 }))
                    }
                    .controlSize(.small)
                }

                Card("Catalog cache", symbol: "externaldrive") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Session summaries are cached by file size and modification time, "
                            + "so a rescan only re-reads transcripts that changed.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Rescan everything from scratch") {
                            Task { await model.refreshCatalog() }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Workshop

    private var workshopTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card("Reloading after a request", symbol: "arrow.triangle.2.circlepath") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Rebuild when a request is marked done", isOn: Binding(
                            get: { model.reloader.isEnabled },
                            set: { model.reloader.isEnabled = $0 }))
                        Text("The workshop agent edits Aviary's own source, so its work is "
                            + "invisible until the binary is rebuilt. This watches the board "
                            + "and starts the build the moment a request finishes, in the "
                            + "background — so by the time you look, the only thing left is "
                            + "the relaunch.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().opacity(0.5)
                        Toggle("Relaunch as soon as the build succeeds", isOn: Binding(
                            get: { model.reloader.autoRelaunch },
                            set: { model.reloader.autoRelaunch = $0 }))
                            .disabled(!model.reloader.isEnabled)
                        Text("Off by default for one specific reason: when the agent finishes "
                            + "a request, the session that finished it is usually still "
                            + "attached and holding a live interpreter. Relaunching ends it. "
                            + "The transcript survives and the session can be resumed, but "
                            + "the variables in that interpreter cannot.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let mode = model.reloader.launchMode {
                            Divider().opacity(0.5)
                            DetailRow(label: "Rebuilds", value: mode.describedTarget, mono: true)
                            Text("Read from the running image's own path, so it rebuilds what "
                                + "you are actually using — rebuilding the other "
                                + "configuration would succeed and change nothing visible.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("This copy of Aviary was not launched from a place that can "
                                + "be rebuilt in situ, so reloading is unavailable.")
                                .font(.system(size: 10)).foregroundStyle(Design.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .controlSize(.small)
                }

                Card("What this is not", symbol: "info.circle") {
                    Text("Not hot reload in the code-injection sense — the process is "
                        + "replaced, not patched. That needs `-Xlinker -interposable` and an "
                        + "injection framework, and there is no Xcode here to hang one off. "
                        + "What makes it feel like a reload instead of a restart is that the "
                        + "build has already happened and the app comes back on the screen "
                        + "you were on. The workshop conversation reopens in a new runtime; "
                        + "Claude Code starts a fresh driven session rather than reattaching "
                        + "its prior process.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    // MARK: About

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Design.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aviary").font(.system(size: 21, weight: .semibold))
                        Text("A native workspace for capable local agents")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }

                Card("How it fits together", symbol: "square.stack.3d.up") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Aviary owns its session journals, model catalog, Python runtime "
                            + "hosts, and in-house agent loop. Claude Code can also drive the "
                            + "same runtime. Work is currently held by this app process; the "
                            + "planned Work Host split will make that ownership independent.")
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().opacity(0.5)
                        DetailRow(label: "Engine", value: model.engine?.displayPath ?? "none", mono: true)
                        DetailRow(label: "Engine version", value: model.engine?.version ?? "—", mono: true)
                        DetailRow(label: "Agent directory", value: model.home.root.path, mono: true)
                        DetailRow(
                            label: "Sessions indexed",
                            value: "\(model.sessions.count)")
                        DetailRow(
                            label: "Sub-agents indexed",
                            value: "\(model.tree.allNodes.count)")
                    }
                }

                Card("What Aviary never does", symbol: "lock.shield") {
                    VStack(alignment: .leading, spacing: 5) {
                        bullet("Reads auth.json's provider names and auth kinds — never the tokens.")
                        bullet("Shows a resolved credential only as a masked prefix and a length.")
                        bullet("Backs up models.json before every write.")
                        bullet("Moves deleted sessions to the Trash; never unlinks a transcript.")
                    }
                }

                Card("Trust model", symbol: "exclamationmark.shield") {
                    Text("Agent Python is intentionally full capability: it can affect files, "
                        + "processes, sockets, and networks directly. Tool hooks can review or "
                        + "rewrite named calls, but they are not a complete sandbox boundary.")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Design.success)
                .padding(.top, 3)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
