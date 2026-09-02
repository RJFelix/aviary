import SwiftUI
import AviaryCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 196, ideal: 216, max: 280)
        } detail: {
            detail
                // An explicit ground for the detail column. Without it the column has no
                // background of its own, which leaves screens whose content does not fill
                // the height sitting on undefined pixels.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .toolbar { toolbarContent }
                .navigationTitle(model.section.title)
                .navigationSubtitle(subtitle)
        }
        .sheet(isPresented: Binding(
            get: { model.showCommandPalette },
            set: { model.showCommandPalette = $0 }))
        {
            CommandPaletteView()
        }
        // Top, and outside the section switch, because the point is that you do not have to
        // be looking at the Workshop to learn that the thing you asked for is ready.
        .overlay(alignment: .top) { ReloadBanner() }
        .overlay(alignment: .bottom) { toastOverlay }
        // Bottom-trailing, on every screen, deliberately outside the section switch: the
        // point of the panel is to catch a reaction wherever you have it.
        .overlay(alignment: .bottomTrailing) { CapturePanel() }
        .animation(.easeInOut(duration: 0.18), value: model.toast?.id)
        .animation(.easeInOut(duration: 0.2), value: model.reloader.phase)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
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
    }

    private var subtitle: String {
        switch model.section {
        case .cockpit:
            return model.engine.map { "\($0.kind.label) · \($0.version ?? "unknown version")" } ?? "No engine"
        case .sessions:
            let archived = model.sessions.filter(\.isArchived).count
            let current = model.sessions.count - archived
            return archived == 0
                ? "\(current) sessions"
                : "\(current) current · \(archived) archived"
        case .workshop:
            return "\(model.board.openCount) open · \(model.board.workingCount) in progress · "
                + "\(model.board.requests.count) total"
        case .live:
            let live = model.workRuns.filter { !$0.hasExited }
            return "\(live.count) live · \(model.runs.count) attached · "
                + "\(live.filter(\.isStreaming).count) working"
        case .flock:
            let works = model.canonicalFlockInventory
            let children = works.flatMap(\.children).count
            let attention = CanonicalFlockCatalogProjection.attentionSessionCount(works)
            let legacyIDs = Set(CanonicalFlockCatalogProjection.legacyCompatibilityRootIDs(
                Array(model.tree.byParentSession.keys),
                nativeCompanionLegacyIDs: model.nativeCompanionLegacyIDs))
            let legacyChildren = model.tree.byParentSession
                .filter { legacyIDs.contains($0.key) }
                .flatMap(\.value).flatMap(\.flattened).count
            return "\(works.count) Work · \(children) children · \(attention) attention"
                + (legacyChildren == 0 ? "" : " · \(legacyChildren) legacy children")
        case .models:
            return "\(model.runtimeModels.count) reachable · \(model.modelsConfig.providers.count) configured providers"
        case .usage:
            return "\(Fmt.tokens(model.analytics.total.totalTokens)) tokens across \(model.analytics.sessionCount) sessions"
        case .library:
            // Counted by what a run would get, not by what was found on disk: the engine
            // bundle's own skills are loaded by that engine, never by Aviary.
            let engineOnly = model.library.engineOnlySkills.count
            let reachable = model.library.reachableSkills.count
            return "\(reachable) skills"
                + (engineOnly > 0 ? " · \(engineOnly) engine-only" : "")
                + " · \(model.library.prompts.count) prompts"
                + " · \(model.library.extensions.count) extensions"
        case .health:
            return model.runtimeProbes.contains(where: \.ok)
                ? "runtime ready" : "runtime unavailable"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isScanning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    if model.scanProgress.total > 0 {
                        Text("\(model.scanProgress.done)/\(model.scanProgress.total)")
                            .font(Design.numeric(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                model.showCommandPalette = true
            } label: {
                Image(systemName: "command")
            }
            .help("Command palette (⌘K)")

            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh everything (⌘R)")

            Button {
                model.showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Toggle inspector (⌥⌘I)")
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Design.danger : Design.success)
                Text(toast.message)
                    .font(.system(size: 11.5))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Button {
                    model.toast = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 3)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if model.toast?.id == toast.id { model.toast = nil }
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The solid fill sits *under* the sidebar's vibrancy material: invisible in the
        // running app, but it means an offscreen capture (which cannot rasterize AppKit
        // materials) shows a sensible colour instead of bare white.
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            sidebarList
        }
    }

    private var sidebarList: some View {
        List(selection: Binding(
            get: { model.section },
            set: { model.section = $0 ?? .cockpit }))
        {
            SwiftUI.Section {
                ForEach(Section.visible) { s in
                    SidebarRow(section: s, badge: badge(for: s))
                        .tag(s)
                }
            }

            if !model.runs.isEmpty {
                SwiftUI.Section("Attached runs") {
                    ForEach(model.runs) { run in
                        Button {
                            model.focusedRunID = run.id
                            model.section = .live
                        } label: {
                            HStack(spacing: 6) {
                                if run.isStreaming {
                                    PulseDot(color: Design.success)
                                } else if run.hasExited {
                                    Image(systemName: "stop.circle")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Circle().fill(.tertiary).frame(width: 7, height: 7)
                                }
                                Text(run.title)
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.detachedRuns.isEmpty {
                SwiftUI.Section("Detached Work") {
                    ForEach(model.detachedRuns) { run in
                        Button {
                            model.reattachRun(run)
                        } label: {
                            HStack(spacing: 6) {
                                if run.isStreaming { PulseDot(color: Design.success) }
                                else { Circle().fill(.tertiary).frame(width: 7, height: 7) }
                                Text(run.title).font(.system(size: 11.5)).lineLimit(1)
                                Spacer()
                                Image(systemName: "arrowshape.turn.up.left")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Reattach this run")
                    }
                }
            }

            // The "Working agents" section is deliberately not shown — it listed sessions
            // the harness daemon is holding, and on the in-house engine it was actively wrong:
            // a live in-house run still rendered "Nothing running". Kept as
            // `WorkingAgentsSection`; see docs/architecture.md, "Retired daemon surfaces".
        }
        .listStyle(.sidebar)
        // The sidebar's own vibrancy is removed. The original reason no longer holds — that
        // was a `cacheDisplay` limitation, and captures now go through the WindowServer, which
        // composites materials fine. Kept solid because a ground that renders identically in
        // the app and in a screenshot is worth more here than the material was, but this is
        // now a preference rather than a constraint.
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    }

    private func badge(for s: Section) -> (String, Color)? {
        switch s {
        case .live:
            let n = model.workRuns.filter(\.isStreaming).count
            return n > 0 ? ("\(n)", Design.success) : nil
        case .sessions:
            return model.sessions.isEmpty ? nil : ("\(model.sessions.count)", .secondary)
        case .workshop:
            let n = model.board.openCount
            return n > 0 ? ("\(n)", Design.accent) : nil
        case .flock:
            let legacyIDs = Set(CanonicalFlockCatalogProjection.legacyCompatibilityRootIDs(
                Array(model.tree.byParentSession.keys),
                nativeCompanionLegacyIDs: model.nativeCompanionLegacyIDs))
            let legacyRunning = model.tree.byParentSession
                .filter { legacyIDs.contains($0.key) }
                .flatMap(\.value).flatMap(\.flattened).filter(\.isRunning).count
            let n = model.canonicalFlockInventory.filter(\.isRunning).count + legacyRunning
            return n > 0 ? ("\(n)", Design.agentMessage) : nil
        case .health:
            // Only shouts when the runtime has been probed and failed. An unprobed runtime is
            // not a fault, and a badge that appeared at launch would be noise every time.
            guard !model.runtimeProbes.isEmpty,
                  !model.runtimeProbes.contains(where: \.ok)
            else { return nil }
            return ("!", Design.danger)
        default:
            return nil
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Aviary")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    Text(model.runtimeProbes.first(where: \.ok)?.summary ?? "runtime unchecked")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                // The loudest thing in the footer when it applies, because a stale bundle is
                // indistinguishable from a failed fix until somebody notices it.
                if let behind = model.commitsBehind {
                    Chip(text: "\(behind) behind", symbol: "exclamationmark.triangle.fill",
                         tint: Design.warning, filled: true)
                        .help("This app was \(model.buildStamp.summary). The checkout has "
                            + "\(behind) commit(s) since. Run `just build` and reopen it.")
                }
                let working = model.workRuns.filter(\.isStreaming).count
                if working > 0 {
                    Chip(text: "\(working)", symbol: "bolt.fill", tint: Design.success)
                        .help("\(working) run(s) working")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var healthColor: Color {
        if model.runtimeProbes.isEmpty { return .secondary }
        return model.runtimeProbes.contains(where: \.ok) ? Design.success : Design.danger
    }
}

struct SidebarRow: View {
    let section: Section
    let badge: (String, Color)?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: section.symbol)
                .font(.system(size: 12))
                .frame(width: 17)
            Text(section.title)
                .font(.system(size: 12.5))
            Spacer(minLength: 4)
            if let badge {
                Text(badge.0)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(badge.1.opacity(0.18)))
                    .foregroundStyle(badge.1)
            }
        }
        .padding(.vertical, 1)
    }
}
