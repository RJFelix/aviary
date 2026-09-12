import AppKit
import AviaryCore
import SwiftUI
@preconcurrency import UserNotifications

@main
struct AviaryApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// When this process started, for the preview loop's own timing line.
    static let launchedAt = Date()

    init() {
        _ = Self.launchedAt
        AviaryTelemetry.configure(serviceName: "aviary", environment: ProcessInfo.processInfo.environment)
        // Headless modes short-circuit before any scene is created, and exit.
        ChatJourneyProbe.runIfRequested()
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
                    delegate.handleNotification = { route in
                        model.openCanonicalNotification(route)
                    }
                    if CanonicalNotificationPlatform.isAvailable {
                        UNUserNotificationCenter.current().delegate = delegate
                    }
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
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let maximumQueuedNotificationRoutes = 32
    var prepareForTermination: (() async -> Bool)?
    var handleNotification: ((CanonicalNotificationRoute) -> Void)? {
        didSet {
            guard let handleNotification else { return }
            let queued = queuedNotificationRoutes
            queuedNotificationRoutes.removeAll()
            queuedNotificationRouteKeys.removeAll()
            queued.forEach(handleNotification)
        }
    }
    private var queuedNotificationRoutes: [CanonicalNotificationRoute] = []
    private var queuedNotificationRouteKeys: Set<String> = []
    private var terminationTask: Task<Void, Never>?

    override init() {
        super.init()
        // Install before the SwiftUI scene/task exists. macOS can deliver a cold-click during
        // launch; routeNotification queues it until AppModel has built its catalog.
        if CanonicalNotificationPlatform.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor [weak self] in
            self?.routeNotification(userInfo)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A foreground Aviary window is already the attention surface. Avoid duplicating the
        // banner while retaining background delivery for the user-enabled notification path.
        completionHandler([])
    }

    private func routeNotification(_ userInfo: [AnyHashable: Any]) {
        guard let route = CanonicalNotificationRoute.decode(userInfo: userInfo) else { return }
        guard let handleNotification else {
            let key = route.deduplicationKey
            guard queuedNotificationRouteKeys.insert(key).inserted else { return }
            queuedNotificationRoutes.append(route)
            if queuedNotificationRoutes.count > Self.maximumQueuedNotificationRoutes,
               let dropped = queuedNotificationRoutes.first
            {
                queuedNotificationRoutes.removeFirst()
                queuedNotificationRouteKeys.remove(dropped.deduplicationKey)
            }
            return
        }
        handleNotification(route)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// AppKit's terminate request is synchronous, while process-owned Claude Code cleanup is
    /// not. Returning `terminateLater` keeps the process alive until those resources quiesce;
    /// `AppModel.stopAllWork()` only disconnects service-backed GUI attachments, so quitting
    /// never sends End or stops durable Work on a Work Host. A nonempty draft that cannot be
    /// flushed cancels termination instead of silently becoming memory loss. This is intentionally
    /// not invoked for last-window close: that event has no user intent to end Work.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor in
            let draftsAndWorkAreReady = await prepareForTermination()
            terminationTask = nil
            sender.reply(toApplicationShouldTerminate: draftsAndWorkAreReady)
        }
        return .terminateLater
    }
}

// MARK: - Menus

struct AviaryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                model.newChatRequested = true
                model.section = .cockpit
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
                Button(s.title) { model.section = s == .live ? .cockpit : s }
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
                        model.section = .cockpit
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
