import AviaryCore
import SwiftUI

/// This is a draft action, not a shell executor. The ordinary chat submission path retains
/// the request and owns delivery, provider execution, output, and interruption semantics.
struct SuggestedCommandSheet: View {
    let command: SuggestedShellCommand
    let run: LiveRun
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask agent to run").font(.headline)
            Label(run.title, systemImage: "bubble.left")
                .font(.subheadline).lineLimit(2)
            Label(run.config.cwd.isEmpty ? run.projectName : run.config.cwd,
                  systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                Text(command.source)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 90, maxHeight: 250)
            .background(Design.codeBackground, in: RoundedRectangle(cornerRadius: 8))
            Text("Prepare a message in this chat, then review it and press Send. "
                + "This asks the agent to run it and report back; it is not a direct terminal.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = failure ?? AgentMessageDraftTransfer.unavailableReason(for: run) {
                Label("Cannot prepare a draft: \(reason). Your existing text is unchanged.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Prepare draft") { prepare() }
                    .buttonStyle(.borderedProminent)
                    .disabled(AgentMessageDraftTransfer.unavailableReason(for: run) != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 520)
    }

    private func prepare() {
        guard let target = model.runs.first(where: { $0.id == run.id }), target === run,
              AgentMessageDraftTransfer.prepare(command.draftText, for: target) else {
            failure = "chat changed or is unavailable"
            return
        }
        dismiss()
    }
}
