import AviaryCore
import SwiftUI

/// The originating Run is captured once. Selection or Run replacement cannot retarget it.
struct SuggestedCommandSheet: View {
    let command: SuggestedShellCommand
    let run: LiveRun
    @Environment(\.dismiss) private var dismiss
    @State private var capturedRun: RunRef?
    @State private var submitting = false
    @State private var failure: String?

    init(command: SuggestedShellCommand, run: LiveRun) {
        self.command = command
        self.run = run
        _capturedRun = State(initialValue: run.serviceProjection?.descriptor.currentRun)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let language = DirectShellLanguage(wireValue: command.language) {
                DirectShellCommandConfirmation(source: command.source, language: language,
                    workspaceLabel: run.projectName,
                    onConfirm: { timeout in
                        guard run.canRunDirectShell, let capturedRun,
                              run.serviceProjection?.descriptor.currentRun == capturedRun else {
                            failure = "This agent session changed or is busy. Nothing was run."
                            return
                        }
                        submitting = true
                        Task {
                            let accepted = await run.directShell(operation: .run, command: command,
                                timeout: timeout, expectedRun: capturedRun)
                            submitting = false
                            // The chat retains Check status if confirmation was lost. No retry
                            // launches a second process from this confirmation sheet.
                            if accepted || run.directShellError != nil { dismiss() }
                        }
                    }, onCancel: { dismiss() })
                    .disabled(submitting || !run.canRunDirectShell)
            }
            if let reason = failure ?? unavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                Button("Done") { dismiss() }.padding(.bottom, 12)
            }
        }
    }

    private var unavailableReason: String? {
        if run.serviceBridge?.supportsDirectShell != true {
            return "Direct commands need an updated local agent service. You can still copy this command."
        }
        if !run.canRunDirectShell { return "Wait for the current work to finish before running this command." }
        return nil
    }
}
