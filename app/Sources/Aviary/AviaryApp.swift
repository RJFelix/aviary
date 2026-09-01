import AppKit
import AviaryCore
import SwiftUI

@main
struct AviaryApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// When this process started, for the preview loop's own timing line.
    static let launchedAt = Date()

    init() {
        _ = Self.launchedAt
        // Headless modes short-circuit before any scene is created, and exit.
        WireInspect.runIfRequested()
        Snapshot.runIfRequested()
        AgentCLI.runIfRequested()
        ClaudeCodeCLI.runIfRequested()
    }

    /// `Aviary --preview <section>` — one screen, opened fast, for a layout pass.
    ///
    /// Read here rather than in a headless mode because this one needs a window: it is the
    /// same views the real app draws, just without the startup work that makes a relaunch feel
    /// like a restart. `scripts/watch.sh` rebuilds and relaunches it on save.
    private static var previewSection: Section? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--preview"), i + 1 < args.count else { return nil }
        return Section(rawValue: args[i + 1])
    }

    var body: some Scene {
        WindowGroup("Aviary", id: "main") {
            RootView()
                .environment(model)
                // Wide enough that the three-pane screens always fit: a 280pt sidebar
                // plus the 800pt the Sessions panes demand together.
                .frame(minWidth: 1100, minHeight: 680)
                .task {
                    delegate.prepareForTermination = { await model.stopAllWork() }
                    if let preview = Self.previewSection {
                        model.bootstrapPreview(section: preview)
                    } else {
                        await model.bootstrap()
                    }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1420, height: 900)
        .commands { AviaryCommands(model: model) }

        Settings {
            PreferencesView()
                .environment(model)
        }

        // A menu-bar readout, because the question "is anything still running?" shouldn't
        // require raising a window.
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var prepareForTermination: (() async -> Void)?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// AppKit's terminate request is synchronous, while Work teardown is not. Returning
    /// `terminateLater` keeps the process alive until Claude Code, the runtime host, session
    /// writers, and their readers have actually quiesced. This is intentionally not invoked
    /// for last-window close: that event has no user intent to end Work.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor in
            await prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Menus

struct AviaryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Run…") {
                model.section = .live
                NotificationCenter.default.post(name: .aviaryNewRun, object: nil)
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Aviary") {
            Button("Command Palette…") { model.showCommandPalette = true }
                .keyboardShortcut("k")
            Button("Improve Aviary…") {
                model.openCapturePanel()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Refresh Everything") { Task { await model.refreshAll() } }
                .keyboardShortcut("r")
            Button("Rescan Sessions") { Task { await model.refreshCatalog() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            ForEach(Section.visible) { s in
                Button(s.title) { model.section = s }
                    .keyboardShortcut(shortcutKey(for: s), modifiers: .command)
            }
        }

        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                model.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle(
                "Hide Thinking Blocks",
                isOn: Binding(
                get: { model.hideThinking },
                set: { model.hideThinking = $0 }))
        }

        CommandGroup(replacing: .help) {
            Button("Prime Agent Docs in Finder") {
                if let engine = model.engine, let cli = engine.leadingArguments.first {
                    let docs = URL(fileURLWithPath: cli)
                        .deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().appending(path: "docs")
                    NSWorkspace.shared.activateFileViewerSelecting([docs])
                }
            }
            Button("Reveal Agent Directory in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.home.root])
            }
        }
    }

    private func shortcutKey(for s: Section) -> KeyEquivalent {
        switch s {
        case .cockpit: return "1"
        case .live: return "2"
        case .sessions: return "3"
        case .workshop: return "9"
        case .flock: return "4"
        case .models: return "5"
        case .usage: return "6"
        case .library: return "7"
        case .health: return "8"
        }
    }
}

extension Notification.Name {
    static let aviaryNewRun = Notification.Name("aviary.newRun")
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    /// Runs this process is holding, not sessions a supervisor claims to hold. With the
    /// harness gone there is only one answer to "what is running": attached plus detached Work.
    private var working: Int {
        model.workRuns.filter(\.isStreaming).count
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: working > 0 ? "bird.fill" : "bird")
            if working > 0 {
                Text("\(working)").font(.system(size: 11, weight: .semibold))
            }
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let live = model.workRuns.filter { !$0.hasExited }
        Text(
            live.isEmpty
            ? "No live agents"
            : "\(live.count) live · \(live.filter(\.isStreaming).count) working")

        if !live.isEmpty {
            Divider()
            ForEach(live.prefix(12)) { s in
                Button {
                    if model.detachedRuns.contains(where: { $0.id == s.id }) {
                        model.reattachRun(s)
                    } else {
                        model.focusedRunID = s.id
                    model.section = .live
                    }
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("\(s.isStreaming ? "▶ " : "· ")\(s.title)")
                }
            }
        }

        Divider()
        Button("Open Aviary") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Aviary") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
