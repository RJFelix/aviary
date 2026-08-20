import SwiftUI
import AppKit
import AviaryCore

@main
struct AviaryApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Headless rendering short-circuits before any scene is created and exits.
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("Aviary") {
            RootView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 680)
                .task { await model.bootstrap() }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
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
            Divider()
            Button("Refresh Everything") { Task { await model.refreshAll() } }
                .keyboardShortcut("r")
            Button("Rescan Sessions") { Task { await model.refreshCatalog() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            ForEach(Section.allCases) { s in
                Button(s.title) { model.section = s }
                    .keyboardShortcut(shortcutKey(for: s), modifiers: .command)
            }
        }

        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                model.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Hide Thinking Blocks", isOn: Binding(
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

    private var working: Int {
        model.liveSessions.filter(\.isWorking).count
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

    var body: some View {
        let live = model.liveSessions
        Text(live.isEmpty
            ? "No live agents"
            : "\(live.count) live · \(live.filter(\.isWorking).count) working")

        if !live.isEmpty {
            Divider()
            ForEach(live.prefix(12)) { s in
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    model.section = .live
                } label: {
                    Text("\(s.isWorking ? "▶ " : "· ")\(s.displayName)")
                }
            }
        }

        Divider()
        Text("Daemon: \(model.daemon.health.label)")
        if model.daemon.kernelCount > 0 {
            Text("\(model.daemon.kernelCount) IPython kernel\(model.daemon.kernelCount == 1 ? "" : "s")")
        }
        Divider()
        Button("Open Aviary") { NSApp.activate(ignoringOtherApps: true) }
        Button("Refresh") { Task { await model.refreshDaemon() } }
        Divider()
        Button("Quit Aviary") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
