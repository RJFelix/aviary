import SwiftUI
import AppKit
import AviaryCore

/// The MCP servers a run will start, and what they turned out to be.
///
/// Two different kinds of fact, kept visibly apart. The configuration is read from
/// `settings.json` and is always true. Everything else — which protocol era the server speaks,
/// what tools it offers, whether it starts at all — is only knowable by *running* it, which
/// costs a child process and whatever that process decides to do on launch. So the config shows
/// unasked and the rest is a button.
///
/// It exists because a server that fails to start was previously invisible until you read a
/// note in a transcript, and the most common failure is the most boring one: an `npx` package
/// that has never been fetched on this machine.
struct MCPPane: View {
    @Environment(AppModel.self) private var model
    var search: String

    private var servers: [MCPConfiguration.Server] {
        let query = search.lowercased()
        guard !query.isEmpty else { return model.mcpServers }
        return model.mcpServers.filter {
            $0.name.lowercased().contains(query) || $0.command.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if servers.isEmpty {
                    EmptyStateView(
                        symbol: "puzzlepiece.extension",
                        title: "No MCP servers configured",
                        message: "Add an `mcpServers` block to settings.json — the same shape "
                            + "other clients use: a name, a `command`, and its `args`. Aviary "
                            + "speaks stdio; an `http` or `sse` entry is skipped rather than "
                            + "half-started.")
                } else {
                    ForEach(servers) { server in
                        card(server)
                    }
                }
            }
            .padding(Design.gutter)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Started per run, not at launch")
                    .font(.system(size: 11.5, weight: .medium))
                Text("A server is a child process holding credentials, so the honest lifetime "
                    + "for one is the run that asked for it. Probing here starts them once, "
                    + "reads their tools, and stops them again.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.probeMCPServers() }
            } label: {
                if model.isProbingMCP {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Probing…")
                    }
                } else {
                    Label("Probe all", systemImage: "bolt.horizontal")
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(model.isProbingMCP || model.mcpServers.isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
            .fill(.background.secondary))
    }

    @ViewBuilder
    private func card(_ server: MCPConfiguration.Server) -> some View {
        let probe = model.mcpProbes[server.name]
        Card(server.name, symbol: "puzzlepiece.extension.fill",
             accessory: AnyView(HStack(spacing: 5) {
                if !server.enabled {
                    Chip(text: "disabled", tint: .secondary)
                }
                if let probe {
                    Chip(text: probe.era ?? "unreachable",
                         symbol: probe.error == nil ? "checkmark.seal" : "xmark.octagon",
                         tint: probe.error == nil ? Design.success : Design.danger)
                }
             }))
        {
            VStack(alignment: .leading, spacing: 8) {
                Text(([server.command] + server.arguments).joined(separator: " "))
                    .font(Design.mono(10.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !server.environment.isEmpty {
                    // Names only. The values are credentials, and a diagnostics screen that
                    // prints them is a diagnostics screen you cannot screenshot.
                    Text("env: " + server.environment.keys.sorted().joined(separator: ", "))
                        .font(Design.mono(9.5)).foregroundStyle(.tertiary)
                }

                if let probe {
                    Divider().opacity(0.5)
                    if let error = probe.error {
                        Text(error)
                            .font(.system(size: 11)).foregroundStyle(Design.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        if !probe.diagnostics.isEmpty {
                            Text(probe.diagnostics)
                                .font(Design.mono(9.5)).foregroundStyle(.tertiary)
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text("\(probe.tools.count) tool(s)")
                                .font(Design.numeric(11, weight: .semibold))
                            if let info = probe.serverInfo {
                                Text(info).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        ForEach(probe.tools, id: \.self) { tool in
                            HStack(spacing: 6) {
                                Image(systemName: "wrench.adjustable")
                                    .font(.system(size: 8)).foregroundStyle(Design.tool)
                                // The namespaced name, because that is what the model is
                                // given and therefore what appears in a transcript.
                                Text(tool).font(Design.mono(10))
                                Spacer()
                            }
                        }
                    }
                } else {
                    Text("Not probed. Its tools are only knowable by starting it.")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
