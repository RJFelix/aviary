import SwiftUI
import AviaryCore

/// Choices and stage identity come from Muse. No implied approval or inferred policy.
struct MuseApprovalCard: View {
    var driver: MuseCodeDriver
    @State private var deciding = false
    @State private var submitted: MuseMSPApprovalRequirement?

    var body: some View {
        if let approval = driver.pendingApproval {
            VStack(alignment: .leading, spacing: 8) {
                Label("Muse needs your approval", systemImage: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Design.warning)
                if let detail = approval.detail, !detail.isEmpty {
                    ScrollView {
                        Text(detail).font(Design.mono(11)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 130)
                }
                if submitted == approval.requirement {
                    Label("Decision sent · waiting for Muse", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { choices(approval) }
                        VStack(alignment: .leading) { choices(approval) }
                    }
                }
                Text("Only the displayed approval stage is affected. Stop cancels the turn.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: driver.pendingApproval?.requirement) { _, _ in
                submitted = nil
                deciding = false
            }
        }
    }

    @ViewBuilder private func choices(_ approval: MuseCodeDriver.PendingApproval) -> some View {
        ForEach(approval.choices, id: \.self) { choice in
            Button(approval.labels[choice] ?? choice) {
                deciding = true
                Task {
                    let accepted = await driver.decideApproval(
                        approvalID: approval.approvalID, requirement: approval.requirement,
                        choiceID: choice)
                    if accepted && driver.pendingApproval?.requirement == approval.requirement {
                        submitted = approval.requirement
                    }
                    deciding = false
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(deciding || driver.hasExited)
        }
    }
}
