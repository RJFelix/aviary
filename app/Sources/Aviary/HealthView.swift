import SwiftUI
import AppKit
import AviaryCore

/// Service connectivity, interpreter availability, and provider configuration are separate
/// observations. A successful Python probe does not mean the agent service is reachable.
struct HealthView: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                serviceCard
                verdict
                runtimeCard
                claudeCodeCard
                environmentCard
                pathsCard
            }
            .padding(Design.gutter)
        }

    }

    // MARK: Verdict

    private var serviceCard: some View {
        Card("Local agent service", symbol: "network") {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.localWorkServiceError {
                    Label(model.localWorkServiceHandshake == nil
                          ? "Connection needs attention" : "Connected · chat setup needs attention",
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(Design.danger)
                    Text(error).textSelection(.enabled)
                } else if model.localWorkServiceHandshake != nil {
                    Label("Connected on this Mac", systemImage: "checkmark.circle")
                        .foregroundStyle(Design.success)
                    Text("Aviary can reach the agent service. Project and model readiness are checked when a chat starts.")
                } else {
                    Text("No agent-service connection has been established yet.")
                }
                Text("A connection problem does not discard saved requests or stop work that the service already owns.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry connection") {
                    Task {
                        await model.bootstrapLocalWorkService()
                        await model.refreshServiceWork()
                    }
                }.buttonStyle(.bordered)
            }.font(.system(size: 12))
        }
    }

    /// Interpreter probe only; this is not an overall readiness verdict.
    private var verdict: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(verdictColor.opacity(0.15)).frame(width: 34, height: 34)
                    Image(systemName: verdictSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(verdictColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtimeOK ? "Python interpreter available" : "Python interpreter unavailable")
                        .font(.system(size: 15, weight: .semibold))
                    Text(verdictSubtitle)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .strokeBorder(verdictColor.opacity(0.3), lineWidth: 1))
    }

    private var runtimeOK: Bool { model.runtimeProbes.contains(where: \.ok) }

    private var verdictColor: Color { runtimeOK ? Design.success : Design.danger }

    private var verdictSymbol: String {
        runtimeOK ? "checkmark.circle.fill" : "exclamationmark.octagon.fill"
    }

    private var verdictSubtitle: String {
        guard let probe = model.runtimeProbes.first(where: \.ok) ?? model.runtimeProbes.first
        else { return "No runtime host has been probed yet." }
        let models = model.pickerModels.count
        return probe.summary
            + " · \(models) configured model\(models == 1 ? "" : "s")"
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                Task { busy = true; await model.refreshRuntimeProbes(); busy = false }
            } label: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Re-check", systemImage: "arrow.clockwise").font(.system(size: 11))
                }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(busy)

            Spacer(minLength: 0)
        }
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
                Text("The Work Host owns the Python runtime. python3 isolates each "
                    + "session in its own interpreter; python3-shared trades that for numpy "
                    + "and pandas.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Whether a driven run would work, and whether it would draw on the plan.
    ///
    /// The second question is the one worth a card. Claude Code's auth precedence puts
    /// `ANTHROPIC_API_KEY` and friends *above* subscription OAuth, so a machine with one set
    /// runs perfectly while quietly billing metered credit — a failure with no symptom. Aviary
    /// strips those from a run it launches, but the point of showing them here is that the
    /// stripping is doing work you cannot otherwise see.
    private var claudeCodeCard: some View {
        let auth = model.claudeCodeAuth
        let hijackers = ClaudeCode.strippedVariables.filter {
            $0.hasPrefix("ANTHROPIC_") && ProcessEnvironment.shared.has($0)
        }
        let ready = auth?.loggedIn == true
        return Card("Claude Code", symbol: "wand.and.stars",
                    accessory: AnyView(
                        Text(ready ? (auth?.isSubscription == true ? "plan" : "metered")
                                   : "unavailable")
                            .font(.system(size: 9))
                            .foregroundStyle(ready
                                ? (auth?.isSubscription == true
                                    ? Design.success : Design.warning)
                                : Design.warning)))
        {
            VStack(alignment: .leading, spacing: 7) {
                if let auth {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(auth.loggedIn ? Design.success : Design.danger)
                            .frame(width: 7, height: 7)
                        Text(auth.summary).font(.system(size: 11.5, weight: .medium))
                        Spacer(minLength: 0)
                        if let email = auth.email {
                            Text(email).font(Design.mono(9.5)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if !auth.isSubscription, auth.loggedIn {
                        Text("This login is not a subscription one, so a driven run bills "
                            + "metered API credit rather than the plan — which removes the "
                            + "only reason to drive Claude Code rather than call the model "
                            + "directly.")
                            .font(.system(size: 10)).foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("No `claude` binary found in the usual install locations. A shim "
                        + "under /var/folders is ignored on purpose: it belongs to whichever "
                        + "terminal session created it and is gone tomorrow.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !hijackers.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(Design.warning)
                        Text("\(hijackers.joined(separator: ", ")) "
                            + (hijackers.count == 1 ? "is" : "are")
                            + " set in your shell. Claude Code ranks that above the "
                            + "subscription, so a run started from a terminal would bill "
                            + "metered credit. Aviary strips it from runs it launches.")
                            .font(.system(size: 10)).foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Claude Code drives; Aviary's kernel is its only tool. The transcript is "
                    + "written in Aviary's own format, so every other screen reads a driven "
                    + "run like any other.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    + "~/.local/bin, and none of your exported credentials. Aviary loads your "
                    + "login-shell configuration once at startup and hands the resulting "
                    + "environment to every engine process, "
                    + "so it behaves as if you had launched it from a terminal.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.5)
                DetailRow(
                    label: "PATH entries",
                    value: "\((ProcessEnvironment.shared.value("PATH") ?? "").split(separator: ":").count)")
                DetailRow(label: "SHELL", value: ProcessEnvironment.shared.value("SHELL") ?? "—", mono: true)
                DetailRow(label: "TMPDIR", value: ProcessInfo.processInfo
                    .environment["TMPDIR"] ?? NSTemporaryDirectory(), mono: true)
                DetailRow(
                    label: "Variables",
                    value: "\(ProcessEnvironment.shared.snapshot.count) captured")
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

}
