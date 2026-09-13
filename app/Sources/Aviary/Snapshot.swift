import SwiftUI
import AppKit
import AviaryCore

/// Offscreen rendering of Aviary's screens to PNG files.
///
/// `Aviary --snapshot <dir> [--width N] [--height N]` boots the model against the real
/// agent directory, renders each section with `ImageRenderer`, writes a PNG per screen, and
/// exits. It exists because a GUI's only real test is what it draws: a view that compiles,
/// has correct data, and lays out to an empty rectangle is a bug no unit test catches.
/// Being able to produce that evidence without a display server — from CI, from a remote
/// shell, from an agent that cannot take a screenshot — is worth the fifty lines.
enum Snapshot {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--snapshot")
    }

    static func runIfRequested() {
        guard isRequested else { return }
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--snapshot"),
              args.count > flagIndex + 1
        else {
            FileHandle.standardError.write(Data("usage: Aviary --snapshot <dir> [--fixture <route>]\n".utf8))
            exit(2)
        }
        let outDir = URL(fileURLWithPath: args[flagIndex + 1], isDirectory: true)
        let width = value(of: "--width", in: args) ?? 1440
        let height = value(of: "--height", in: args) ?? 900
        let only = stringValue(of: "--only", in: args)
        // Render the section view on its own, without the navigation chrome. Useful when a
        // screen comes back blank and you need to know whether the fault is in the view or
        // in its container.
        let bare = args.contains("--bare")
        // Render with a specific session selected, rather than the largest one.
        let sessionID = stringValue(of: "--session", in: args)
        let fixtureValue = stringValue(of: "--fixture", in: args)

        // AppKit has to be alive for CoreAnimation-backed rendering, but the run loop must
        // not start — so initialise the shared application and never call run().
        NSApplication.shared.setActivationPolicy(.accessory)
        if let appearance = stringValue(of: "--appearance", in: args) {
            switch appearance {
            case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            default:
                FileHandle.standardError.write(Data("appearance must be light or dark\n".utf8))
                exit(2)
            }
        }

        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        if let fixtureValue {
            guard let fixture = VisualFixtureRoute(rawValue: fixtureValue) else {
                FileHandle.standardError.write(
                    Data("unknown fixture route: \(fixtureValue)\n".utf8))
                exit(2)
            }
            runFixture(fixture, outDir: outDir, width: width, height: height)
            return
        }

        // The work has to run on the main actor (SwiftUI, ImageRenderer, AppKit), and
        // nothing drains the main-actor queue unless the main run loop turns. So pump it
        // by hand instead of blocking on a semaphore — blocking the main thread here
        // deadlocks against the very task we are waiting for.
        let state = Progress()
        Task { @MainActor in
            await runSnapshots(outDir: outDir, width: width, height: height, only: only, bare: bare, sessionID: sessionID, state: state)
        }

        let deadline = Date().addingTimeInterval(600)
        while !state.finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if Date() > deadline {
                FileHandle.standardError.write(Data("snapshot timed out\n".utf8))
                exit(1)
            }
        }
        exit(state.failures == 0 ? 0 : 1)
    }

    /// Render a deterministic, in-memory scene without reading the user's agent directory.
    /// This is useful for visual review of states that are rare or timing-sensitive in a real
    /// Work Host: an active action, two attachments, and a durable draft crossing in progress.
    /// The route is intentionally explicit rather than being mixed into normal `--shots` output.
    private static func runFixture(
        _ route: VisualFixtureRoute, outDir: URL, width: Int, height: Int
    ) {
        let state = Progress()
        Task { @MainActor in
            let stage = OffscreenWindow(width: CGFloat(width), height: CGFloat(height))
            defer { stage.close() }
            stage.present(
                VisualFixtureView(route: route)
                    .frame(width: CGFloat(width), height: CGFloat(height))
                    .environment(\.controlActiveState, .key)
                    .environment(\.staticRendering, true))
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                stage.forceDraw()
            }
            let path = outDir.appending(path: "\(route.rawValue).png")
            if let png = await stage.capture(), (try? png.write(to: path)) != nil {
                log("wrote \(path.lastPathComponent) (\(Fmt.bytes(png.count)))")
                state.finish(failures: 0)
            } else {
                log("FAILED \(route.rawValue)")
                state.finish(failures: 1)
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while !state.finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if Date() > deadline {
                FileHandle.standardError.write(Data("fixture snapshot timed out\n".utf8))
                exit(1)
            }
        }
        exit(state.failures == 0 ? 0 : 1)
    }

    /// Mutable progress shared between the pumped run loop and the rendering task.
    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var _finished = false
        private var _failures = 0

        var finished: Bool {
            lock.lock(); defer { lock.unlock() }
            return _finished
        }

        var failures: Int {
            lock.lock(); defer { lock.unlock() }
            return _failures
        }

        func finish(failures: Int) {
            lock.lock()
            _failures = failures
            _finished = true
            lock.unlock()
        }
    }

    @MainActor
    private static func runSnapshots(
        outDir: URL, width: Int, height: Int, only: String?, bare: Bool, sessionID: String?, state: Progress
    ) async {
        var failures = 0
        let model = AppModel()
        log("booting against \(model.home.root.path)…")
        await model.bootstrap()
        model.stopPolling()
        log("indexed \(model.sessions.count) sessions, "
            + "\(model.tree.allNodes.count) sub-agents, "
            + "\(model.runtimeModels.count) reachable models")

        // Give the transcript reader something real to draw.
        let chosen = sessionID.flatMap { id in model.sessions.first { $0.id == id } }
            ?? model.sessions.max(by: { $0.byteSize < $1.byteSize })
        if let biggest = chosen {
            model.select(session: biggest)
            await model.loadTranscript(for: biggest)
            log("loaded \(sessionID == nil ? "the largest" : "the requested") transcript: "
                + "\(model.transcript?.items.count ?? 0) rows from \(Fmt.bytes(biggest.byteSize))"
                + " · \(model.selectedSessionWire.filter { $0.kind == .request }.count) "
                + "recorded payload(s)")
        }

        let stage = OffscreenWindow(width: CGFloat(width), height: CGFloat(height))
        defer { stage.close() }

        // Warm-up: a brand-new window needs several display passes before it draws
        // anything, and capturing forces one.
        // Warm up with something that is *not* any section's view, so the first real
        // present is guaranteed to be a change SwiftUI acts on.
        stage.present(Color(nsColor: .windowBackgroundColor))
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            stage.forceDraw()
        }

        let sections = Section.visible.filter { only == nil || $0.rawValue == only }

        // Two passes, and only the second one writes.
        //
        // The window does not draw reliably until it has been through a couple of section
        // transitions: the first one or two captures come back as an empty frame no matter
        // how long the settle is, and no amount of warm-up on a single view fixes it
        // (forcing a rebuild with .id() makes it worse, because the rebuild then needs more
        // time than the settle allows). Walking the whole list twice sidesteps it entirely
        // for the price of about fifteen seconds.
        for pass in 1...2 {
            for section in sections {
                model.section = section
                stage.present(
                    sectionView(section, bare: bare)
                        .environment(model)
                        .environment(\.staticRendering, true))
                // SwiftUI needs run-loop turns to lay out and draw; the caller is pumping
                // the main run loop, so sleeping here yields to it.
                try? await Task.sleep(nanoseconds: 900_000_000)
                stage.forceDraw()
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard pass == 2 else { continue }
                let url = outDir.appending(path: "\(section.rawValue).png")
                if let png = await stage.capture(), (try? png.write(to: url)) != nil {
                    log("wrote \(url.lastPathComponent) (\(Fmt.bytes(png.count)))")
                } else {
                    log("FAILED \(section.rawValue)")
                    failures += 1
                }
            }
        }
        log("\(sections.count - failures)/\(sections.count) screens rendered")
        state.finish(failures: failures)
    }

    @MainActor @ViewBuilder
    private static func sectionView(_ section: Section, bare: Bool) -> some View {
        if bare {
            switch section {
            case .cockpit: CockpitView()
            case .live: LiveView()
            case .sessions: SessionsView()
            case .workshop: WorkshopView()
            case .flock: FlockView()
            case .models: ModelsView()
            case .usage: UsageView()
            case .library: LibraryView()
            case .health: HealthView()
            }
        } else {
            RootView()
        }
    }

    /// Unbuffered, because a pumped run loop with a redirected stdout will otherwise hold
    /// every line until exit — which makes a hang look like a silent failure.
    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }


    /// Captures a real window's layer tree.
    ///
    /// `ImageRenderer` cannot do this job: it refuses `NavigationSplitView` and draws
    /// SwiftUI's "unsupported" glyph instead — a full-page prohibition sign, which is at
    /// least an unmistakable failure. So we host the view in an actual offscreen `NSWindow`
    /// and ask AppKit to cache its display. That renders the genuine article, split view
    /// and toolbar and all, with no screen-recording permission involved because the window
    /// is ours.
    @MainActor
    final class OffscreenWindow {
        private let window: NSWindow
        private let hosting: NSHostingView<AnyView>
        private let size: CGSize

        init(width: CGFloat, height: CGFloat) {
            size = CGSize(width: width, height: height)
            hosting = NSHostingView(rootView: AnyView(Color.clear))
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            // Ordered onto a real display, because AppKit does not composite a window that
            // sits on no display and the captures come back blank. Left visible: a
            // snapshot run is an explicit developer action, and a window you can see is one
            // you can debug. Click-through so it cannot steal input.
            window.title = "Aviary — snapshot"
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.transient, .ignoresCycle]
            window.center()
            // Raised above other windows and the app activated so the window is genuinely
            // on screen: `SCShareableContent` is queried with `onScreenWindowsOnly: true`,
            // and a window it cannot see is a window it will not capture.
            //
            // Occlusion is *not* why frames came back blank — that theory was tested and
            // falsified (a standalone probe rendered a ScrollView in a NavigationSplitView
            // fine while occluded). The real cause was the capture instrument; see
            // `capture()`.
            window.level = .floating
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }

        func present<V: View>(_ view: V) {
            // The hosting view is sized by the window and resizes with it, rather than the
            // content being pinned with `.frame(width:height:)`.
            //
            // The pinned version looked equivalent and was not: a `NavigationSplitView`
            // given a hard frame lays out its sidebar against a proposal it never receives
            // in the real app, and the sidebar comes back empty — which made five of nine
            // screens capture as blank chrome and, worse, made the tool useless for
            // diagnosing exactly the class of layout bug it exists to catch.
            hosting.rootView = AnyView(view)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.autoresizingMask = [.width, .height]
            hosting.needsLayout = true
            hosting.needsDisplay = true
        }

        /// The composited window, via the WindowServer.
        ///
        /// `cacheDisplay` was the wrong instrument and it took three attempts to see why: it
        /// captures *NSView drawing*, and most SwiftUI content lives in CALayers with no
        /// backing NSView. Measured — the screens that rendered all had 34-45
        /// `ListTableRowView`s (a List in the detail pane, which is AppKit-backed and does
        /// draw), while the blank ones had only the 12 sidebar rows and nothing else. Their
        /// content was never missing; it was never an NSView.
        ///
        /// Asking the WindowServer fixes that, and the two documented artifacts with it:
        /// vibrancy materials and explicitly-set backgrounds now composite properly, so the
        /// sidebar is no longer white and an inspector column no longer flat black.
        /// Nudge AppKit into a real draw pass without paying for a capture.
        ///
        /// The warm-up exists because SwiftUI settles over several frames, not because
        /// anyone wants the bytes. `cacheDisplay` is the cheap way to demand a draw.
        func forceDraw() {
            guard let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
        }

        func capture() async -> Data? {
            if let composited = await WindowShot.composited(window: window) { return composited }
            // Kept as a fallback for a machine without a Screen Recording grant: it renders
            // AppKit-backed content, which is better than nothing and is what this used to do.
            guard let view = window.contentView else { return nil }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }

        func close() { window.close() }
    }

    private static func value(of flag: String, in args: [String]) -> Int? {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return Int(args[i + 1])
    }

    private static func stringValue(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }
}
