import SwiftUI
import AppKit
import AviaryCore

/// Process topology, diagnosis, and repair.
///
/// Three independent signals feed this screen, because each one lies on its own. The
/// engine's own `doctor` completes its handshake against a supervisor that refuses every
/// real command. `ps aux | grep` has been observed returning nothing while four engine
/// processes were running. A socket file outliving its owner looks exactly like a live
/// daemon. Aviary cross-checks all three and names which one disagreed, then offers the
/// one action that actually fixes it.
struct HealthView: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false
    @State private var logTail: [String] = []
    @State private var confirmForce = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                verdict
                // `supervisorCard`, `processCard` and `workersCard` are deliberately not
                // shown. They describe the harness daemon — its pid, socket, ownership lease,
                // kernel and worker processes — and the in-house engine has none of that.
                // Retired rather than deleted: they are intact below and putting one back is
                // adding its name to this list. See docs/architecture.md, "Retired daemon
                // surfaces".
                runtimeCard
                enginesCard
                environmentCard
                logCard
                pathsCard
            }
            .padding(Design.gutter)
        }
        .task { await loadLog() }
        .confirmationDialog(
            "Force-shutdown the background service?",
            isPresented: $confirmForce)
        {
            Button("Force shutdown", role: .destructive) {
                Task { busy = true; await model.shutdownDaemon(force: true); busy = false }
            }
        } message: {
            Text("This escalates to SIGKILL for unresponsive workers. Nothing is lost: "
                + "transcripts are already on disk, and the next launch reaps the dead "
                + "workers and the poisoned ownership lease. Any session mid-model-call "
                + "will stop there.")
        }
    }

    // MARK: Verdict

    private var verdict: some View {
        let d = model.daemon
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(verdictColor.opacity(0.16)).frame(width: 42, height: 42)
                    Image(systemName: verdictSymbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(verdictColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.health.label)
                        .font(.system(size: 17, weight: .semibold))
                    Text(verdictSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }

            if let diagnostic = d.diagnostic {
                Text(diagnostic)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remedy = d.remedy {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9)).foregroundStyle(Design.accent)
                    Text(remedy)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Design.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Design.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .fill(verdictColor.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .strokeBorder(verdictColor.opacity(0.3), lineWidth: 1))
    }

    private var verdictColor: Color {
        switch model.daemon.health {
        case .healthy: return Design.success
        case .notRunning: return .secondary
        case .wedged: return Design.danger
        case .versionMismatch, .unknown: return Design.warning
        }
    }

    private var verdictSymbol: String {
        switch model.daemon.health {
        case .healthy: return "checkmark.circle.fill"
        case .notRunning: return "moon.zzz.fill"
        case .wedged: return "exclamationmark.octagon.fill"
        case .versionMismatch: return "arrow.triangle.branch"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var verdictSubtitle: String {
        let d = model.daemon
        switch d.health {
        case .healthy:
            return "\(d.sessionCount ?? 0) session(s) held · \(d.kernelCount) kernel(s) · "
                + "checked \(Fmt.ago(d.checkedAt))"
        case .notRunning:
            return "The supervisor starts on demand when you begin a session."
        case .wedged:
            return "Holding the socket but refusing commands."
        case .versionMismatch:
            return "Another engine build owns the socket."
        case .unknown:
            return "Answered the handshake but the follow-up command did not come back clean."
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                Task { busy = true; await model.refreshDaemon(); await loadLog(); busy = false }
            } label: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Re-check", systemImage: "arrow.clockwise").font(.system(size: 11))
                }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(busy)

            Button {
                Task { busy = true; await model.repairDaemon(); busy = false }
            } label: {
                Label("doctor --fix", systemImage: "bandage").font(.system(size: 11))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(busy || !model.daemon.isRunning)
            .help("Clears stale sockets and idle orphans. It deliberately skips a "
                + "wedged-but-live supervisor, which reports itself as current.")

            Button {
                confirmForce = true
            } label: {
                Label("Force shutdown", systemImage: "power").font(.system(size: 11))
            }
            .buttonStyle(.bordered).controlSize(.small).tint(Design.danger)
            .disabled(busy || !model.daemon.isRunning)
        }
    }

    // MARK: Cards

    private var supervisorCard: some View {
        Card("Supervisor", symbol: "server.rack") {
            let d = model.daemon
            VStack(alignment: .leading, spacing: 5) {
                DetailRow(label: "PID", value: d.pid.map(String.init) ?? "—", mono: true)
                DetailRow(label: "Version", value: d.version ?? "—", mono: true)
                DetailRow(label: "Build", value: d.buildID ?? "—", mono: true)
                DetailRow(label: "Protocol", value: d.protocolVersion.map(String.init) ?? "—", mono: true)
                DetailRow(label: "Sessions held", value: d.sessionCount.map(String.init) ?? "—")
                DetailRow(
                    label: "Tracked workers",
                    value: d.hasTrackedWorkers ? "yes" : "no")
                DetailRow(label: "Executable", value: d.executablePath ?? "—", mono: true)
                Divider().opacity(0.5)
                DetailRow(label: "Socket", value: d.socketPath, mono: true)
                DetailRow(
                    label: "Socket file",
                    value: d.socketExists ? "present" : "absent",
                    tint: d.socketExists && d.health == .notRunning ? Design.warning : nil)
                if d.socketExists, d.health == .notRunning {
                    Text("A socket with nothing behind it is a stale file, not a running "
                        + "daemon — the next session start clears it.")
                        .font(.system(size: 10)).foregroundStyle(Design.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var processCard: some View {
        Card("Processes", symbol: "list.bullet.indent") {
            let d = model.daemon
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    StatTile(label: "kernels", value: "\(d.kernelCount)",
                             symbol: "cube.fill", tint: Design.tool)
                    StatTile(label: "engine procs", value: "\(d.clientPIDs.count)",
                             symbol: "gearshape.2.fill")
                    StatTile(label: "workers", value: "\(model.workers.filter(\.processAlive).count)",
                             symbol: "square.stack.3d.up.fill")
                }
                Text("Counted with pgrep -fl, not `ps aux | grep` — the latter has been "
                    + "observed returning nothing while four engine processes were running, "
                    + "which reads as “no daemon” and sends you down the wrong path.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if d.kernelCount > 0 {
                    Divider().opacity(0.5)
                    Text("KERNEL PIDS")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(d.kernelPIDs.map(String.init).joined(separator: "  "))
                        .font(Design.mono(10)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(width: 380)
    }

    private var runtimeCard: some View {
        Card("Aviary's own runtime", symbol: "cube.transparent",
             accessory: AnyView(
                Text(model.runtimeProbes.contains(where: \.ok) ? "ready" : "unavailable")
                    .font(.system(size: 9))
                    .foregroundStyle(model.runtimeProbes.contains(where: \.ok)
                        ? Design.success : Design.warning)))
        {
            VStack(alignment: .leading, spacing: 9) {
                if model.runtimeProbes.isEmpty {
                    Text("Not checked yet.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(model.runtimeProbes, id: \.variant) { probe in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(probe.ok ? Design.success : Design.danger)
                                .frame(width: 7, height: 7)
                            Text(probe.variant)
                                .font(.system(size: 11.5, weight: .medium))
                            Text(probe.summary)
                                .font(.system(size: 10.5))
                                .foregroundStyle(probe.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Design.danger))
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        if let capabilities = probe.capabilities {
                            // One wrapping line of text rather than a row of chips: a chip row
                            // cannot wrap, and eight of them overflow a 380pt column — which
                            // does not clip, it stops the whole pane resolving and the screen
                            // comes back blank. Same trap as the Workshop header.
                            Text(capabilities.features.filter(\.value).keys.sorted()
                                .joined(separator: " · "))
                                .font(.system(size: 9.5))
                                .foregroundStyle(Design.tool)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(probe.scriptPath)
                            .font(Design.mono(9.5)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Text("No daemon and no Node, so no version conflict. python3 isolates each "
                    + "session in its own interpreter; python3-shared trades that for numpy "
                    + "and pandas.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enginesCard: some View {
        Card("Engines found", symbol: "cpu") {
            VStack(alignment: .leading, spacing: 6) {
                if model.engines.isEmpty {
                    Text("No prime-agent build found. Aviary looks for the bundled fork's "
                        + "built CLI first, then for an installed prime-agent resolved "
                        + "through your login shell.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.engines) { e in
                        HStack(spacing: 8) {
                            Image(systemName: model.engine == e
                                ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(model.engine == e ? Design.accent : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(e.kind.label).font(.system(size: 11.5, weight: .medium))
                                    if let v = e.version {
                                        Chip(text: v, tint: .secondary)
                                    }
                                }
                                Text(e.displayPath)
                                    .font(Design.mono(9.5)).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                                if !e.note.isEmpty {
                                    Text(e.note).font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if model.engine != e {
                                Button("Use") { model.engine = e }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture { model.engine = e }
                    }
                }
                if model.daemon.health == .versionMismatch {
                    Divider().opacity(0.5)
                    Text("The running daemon belongs to a different build than the engine "
                        + "Aviary is using. Two builds cannot share one socket namespace: "
                        + "either select the engine whose version matches the daemon, or "
                        + "shut the daemon down once its busy sessions finish.")
                        .font(.system(size: 10.5)).foregroundStyle(Design.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var environmentCard: some View {
        Card("Environment", symbol: "leaf") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: model.loginShellEnvironmentLoaded
                        ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.loginShellEnvironmentLoaded
                            ? Design.success : Design.warning)
                    Text(model.loginShellEnvironmentLoaded
                        ? "Using your login shell's environment"
                        : "Using launchd's environment")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                Text("A macOS app inherits launchd's environment, not the one your shell "
                    + "builds — so an app-launched agent would see no asdf shims, no "
                    + "~/.local/bin, and none of your exported credentials. Aviary snapshots "
                    + "`zsh -ilc env` once at startup and hands that to every engine process, "
                    + "so it behaves as if you had launched it from a terminal.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.5)
                DetailRow(
                    label: "PATH entries",
                    value: "\((ProcessEnvironment.shared.value("PATH") ?? "").split(separator: ":").count)")
                DetailRow(label: "SHELL", value: ProcessEnvironment.shared.value("SHELL") ?? "—", mono: true)
                DetailRow(label: "TMPDIR", value: AgentHome.socketDir.path, mono: true)
                DetailRow(
                    label: "Variables",
                    value: "\(ProcessEnvironment.shared.snapshot.count) captured")
            }
        }
    }

    private var workersCard: some View {
        Card("Workers", symbol: "square.stack.3d.up",
             accessory: AnyView(
                Text("read from daemon-workers/, so this works even when the daemon does not")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)))
        {
            if model.workers.isEmpty {
                Text("No worker descriptors on disk.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("WORKER").frame(width: 100, alignment: .leading)
                        Text("PID").frame(width: 52, alignment: .trailing)
                        Text("STATE").frame(width: 66, alignment: .leading)
                        Text("LAST OPERATION").frame(maxWidth: .infinity, alignment: .leading)
                        Text("ORPHANS").frame(width: 58, alignment: .trailing)
                        Text("SEEN").frame(width: 62, alignment: .trailing)
                    }
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                    Divider()
                    ForEach(model.workers.prefix(24)) { w in
                        HStack(spacing: 8) {
                            Text(w.id).font(Design.mono(10))
                                .frame(width: 100, alignment: .leading).lineLimit(1)
                            Text("\(w.pid)").font(Design.mono(10))
                                .frame(width: 52, alignment: .trailing)
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(w.processAlive
                                        ? (w.busy ? Design.success : Design.accent)
                                        : Color.secondary.opacity(0.3))
                                    .frame(width: 6, height: 6)
                                Text(w.processAlive ? (w.busy ? "busy" : "idle") : "dead")
                                    .font(.system(size: 9.5))
                            }
                            .frame(width: 66, alignment: .leading)
                            Text(w.lastOperation ?? "—")
                                .font(Design.mono(9.5))
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            Text(w.orphanPIDs.isEmpty ? "—" : "\(w.orphanPIDs.count)")
                                .font(Design.numeric(10))
                                .foregroundStyle(w.orphanPIDs.isEmpty ? .secondary : Color(Design.warning))
                                .frame(width: 58, alignment: .trailing)
                                .help(w.orphanPIDs.isEmpty ? "" :
                                    "Detached processes this worker is responsible for reaping: "
                                        + w.orphanPIDs.map(String.init).joined(separator: ", "))
                            Text(Fmt.ago(w.recordedAt))
                                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                .frame(width: 62, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        if w.id != model.workers.prefix(24).last?.id { Divider().opacity(0.3) }
                    }
                    if model.workers.count > 24 {
                        Text("+\(model.workers.count - 24) more descriptors")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .padding(.top, 5)
                    }
                }
            }
        }
    }

    private var logCard: some View {
        Card("Agent log", symbol: "doc.text.magnifyingglass",
             accessory: AnyView(
                HStack(spacing: 8) {
                    Button("Reload") { Task { await loadLog() } }
                        .buttonStyle(.link).font(.system(size: 10))
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.home.agentLog])
                    }
                    .buttonStyle(.link).font(.system(size: 10))
                }))
        {
            if logTail.isEmpty {
                Text("Nothing in \(model.home.agentLog.lastPathComponent).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                CodeBlock(text: logTail.joined(separator: "\n"), language: "agent.jsonl",
                          maxLines: 14, tint: .secondary)
            }
        }
    }

    private var pathsCard: some View {
        Card("Where things live", symbol: "folder") {
            VStack(alignment: .leading, spacing: 4) {
                pathRow("Agent directory", model.home.root)
                pathRow("Sessions", model.home.sessionsDir)
                pathRow("Sub-agent artifacts", model.home.artifactsDir)
                pathRow("Spawn ledger", model.home.rlmLedgerDir)
                pathRow("Worker descriptors", model.home.workersDir)
                pathRow("Kernel venv", model.home.kernelVenv)
                pathRow("Socket directory", AgentHome.socketDir)
            }
        }
    }

    private func pathRow(_ label: String, _ url: URL) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(url.path).font(Design.mono(10)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Image(systemName: FileManager.default.fileExists(atPath: url.path)
                ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FileManager.default.fileExists(atPath: url.path)
                    ? Design.success : Color.secondary.opacity(0.4))
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    // MARK: Log

    private func loadLog() async {
        let url = model.home.agentLog
        let lines = await Task.detached(priority: .utility) { () -> [String] in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            // Read only the tail: this file grows without bound.
            let size = (try? handle.seekToEnd()) ?? 0
            let window: UInt64 = 24_000
            try? handle.seek(toOffset: size > window ? size - window : 0)
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").suffix(40).map(String.init)
        }.value
        logTail = lines
    }
}
