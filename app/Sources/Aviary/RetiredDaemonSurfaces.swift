import AviaryCore
import SwiftUI

/// Views that described the harness daemon, kept but not displayed.
///
/// The in-house engine has no supervisor process, no ownership lease, no pool of IPython
/// kernels and no notion of a session held somewhere else — it runs its agents in-process and
/// its interpreters in a runtime host it owns. These surfaces answered questions that only make
/// sense about the harness, and on the in-house engine they answered them wrongly: a live
/// in-house run still reported "the background service is holding no sessions".
///
/// Kept rather than deleted because the harness is still selectable, and because retiring a
/// screen is a cheaper decision to reverse than rebuilding it. Nothing references this file;
/// putting a surface back is adding its name to the relevant `body`.
///
/// The rest of the retired surfaces stayed where they were, since they were already extracted:
/// `HealthView.supervisorCard`, `.processCard`, `.workersCard`, `CockpitView.workingNow`, and
/// the "Working agents" sidebar section in `RootView`.

/// Sessions the harness daemon is holding, including ones started from a terminal.
struct RunningElsewhereCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
}

/// Daemon-held sessions that are mid-turn, as a sidebar section.
struct WorkingAgentsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SwiftUI.Section("Working agents") {
            let working = model.liveSessions.filter(\.isWorking)
            if working.isEmpty {
                Text("Nothing running")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(working.prefix(8)) { s in
                    Button {
                        model.openTranscript(sessionID: s.sessionID)
                    } label: {
                        HStack(spacing: 6) {
                            PulseDot(color: s.isSubagent ? Design.agentMessage : Design.success)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.displayName)
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                                if let m = s.modelLabel {
                                    Text(m)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if working.count > 8 {
                    Text("+\(working.count - 8) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
