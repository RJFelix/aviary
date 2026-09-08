import AviaryCore
import SwiftUI

/// The primary surface reports only recorded activity. Missing intent, timing, causality, and
/// speculative next steps belong in the evidence view, not in three permanent warning columns.
struct WorkActivityStrip: View {
    let action: WorkActionPresentation
    let concurrentActions: [WorkActionPresentation]
    let onInspect: (WorkActionPresentation) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            PulseDot(color: WorkActionVisuals.tint(for: action.state))
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.intent ?? action.kindTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(action.kindTitle)
                    Text("·")
                    Text(action.stateTitle)
                    if concurrentActions.count > 1 {
                        Text("· \(concurrentActions.count) active actions")
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 5)
            Menu {
                ForEach(concurrentActions) { candidate in
                    Button(menuLabel(candidate)) {
                        onInspect(candidate)
                    }
                }
            } label: {
                Text("Details")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Current activity details")
        }
        .padding(.horizontal, Design.gutter).padding(.vertical, 10)
        .background(Design.accent.opacity(0.055))
    }

    private func menuLabel(_ candidate: WorkActionPresentation) -> String {
        let subject = String((candidate.intent ?? candidate.affectedTarget ?? candidate.kindTitle)
            .replacingOccurrences(of: "\n", with: " ").prefix(64))
        return "\(subject) · \(candidate.stateTitle) · …\(candidate.id.suffix(8))"
    }
}

/// A chat-local home for completed actions as well as live ones. This reads the same bounded
/// projection as the inspector and keeps omissions visible; it never labels this a full audit.
struct ChatActivityHistoryView: View {
    var run: LiveRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent activity").font(.headline)
                    Text("Current and recently recorded actions")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let omissions = run.serviceProjectionOmissionSummary {
                        Text(omissions).font(.caption).foregroundStyle(.secondary)
                    }
                    if run.serviceActionPresentations.isEmpty {
                        Text("No recorded actions are available in this view.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(run.serviceActionPresentations) { action in
                        WorkActionLensRow(action: action)
                        Divider()
                    }
                }.padding(16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent activity")
    }
}

/// The inspector's action row keeps the semantic facts visible and the protocol evidence
/// collapsible. Status is always textual; color is only reinforcement.
struct WorkActionLensRow: View {
    let action: WorkActionPresentation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    Circle().fill(tint).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(action.kindTitle)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(action.stateTitle)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                        Text(action.intent ?? "Intent not recorded")
                            .font(.system(size: 10))
                            .foregroundStyle(action.intent == nil ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 2)
                    if let duration = action.durationSeconds {
                        Text(Fmt.duration(duration))
                            .font(Design.numeric(9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work-action-\(action.actionID)")
            .accessibilityLabel("\(action.kindTitle), \(action.stateTitle)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides canonical action evidence")

            if expanded {
                HStack(alignment: .top, spacing: 5) {
                    Text("Could affect")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(action.affectedTarget ?? "target not recorded")
                        .font(Design.mono(9))
                        .foregroundStyle(action.affectedTarget == nil ? .tertiary : .secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            if let retry = action.retryGuidance,
               expanded || action.state == .failed || action.state == .indeterminateEffect,
               action.retrySafety == .unsafe || action.retrySafety == .unknown
                    || action.retrySafety == nil || action.state == .indeterminateEffect {
                Label(retry, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(action.state == .indeterminateEffect ? Design.danger : Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if expanded {
                WorkActionEvidenceDetails(action: action)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 3)
    }

    private var tint: Color { WorkActionVisuals.tint(for: action.state) }
}

struct WorkActionDetailSheet: View {
    let action: WorkActionPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(WorkActionVisuals.tint(for: action.state))
                    .frame(width: 8, height: 8)
                Text(action.kindTitle)
                    .font(.system(size: 14, weight: .semibold))
                Chip(text: action.stateTitle, tint: WorkActionVisuals.tint(for: action.state))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card("Action", symbol: "bolt.horizontal.circle") {
                        VStack(alignment: .leading, spacing: 6) {
                            DetailRow(label: "Intent", value: action.intent ?? "not recorded")
                            DetailRow(
                                label: "Could affect",
                                value: action.affectedTarget ?? "target not recorded", mono: true)
                            DetailRow(label: "Scope", value: action.scope ?? "not recorded")
                            DetailRow(label: "Timing", value: action.timeAvailability)
                            if let duration = action.durationSeconds {
                                DetailRow(label: "Duration", value: Fmt.duration(duration), mono: true)
                            }
                            if let failure = action.failureGuidance {
                                DetailRow(label: "Outcome", value: failure)
                            }
                            if let retry = action.retryGuidance {
                                DetailRow(label: "Retry", value: retry)
                            }
                        }
                    }
                    Card("Observation boundary", symbol: "scope") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(action.boundaryDisclosure)
                                .font(.system(size: 10.5))
                                .fixedSize(horizontal: false, vertical: true)
                            Divider().opacity(0.5)
                            evidenceLine("Input", action.availability.exactInput)
                            evidenceLine("Output", action.availability.output)
                            evidenceLine("Effects", action.availability.effects)
                            evidenceLine("Confirmation", action.availability.confirmation)
                            evidenceLine("Checkpoint", action.availability.checkpoint)
                            if action.metadataEntryCount > 0 {
                                Text(
                                    "\(action.metadataEntryCount) metadata field"
                                        + "\(action.metadataEntryCount == 1 ? "" : "s") recorded; values stay hidden"
                                        + (action.metadataWasTruncated ? " · source was truncated" : ""))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Card("Canonical evidence", symbol: "link") {
                        WorkActionEvidenceDetails(action: action)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 660, height: 720)
    }

    private func evidenceLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A selected action can leave the bounded current/recent page while its inspector is open.
/// Closing over the old value would falsely present it as current canonical state.
struct WorkActionUnavailableSheet: View {
    let actionID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Action no longer in view", systemImage: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            Text(
                "The latest bounded Work projection no longer retains this action. "
                    + "Aviary will not continue showing the stale lifecycle snapshot that was open."
            )
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            DetailRow(label: "Action id", value: actionID, mono: true)
            Spacer()
        }
        .padding(14)
        .frame(width: 520, height: 240)
    }
}

private struct WorkActionEvidenceDetails: View {
    let action: WorkActionPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            DetailRow(label: "Action id", value: action.actionID, mono: true)
            if action.identifierWasTruncated {
                Text("The displayed identifier was truncated at a bounded projection boundary.")
                    .font(.system(size: 9)).foregroundStyle(Design.warning)
            }
            lifecycle("Intent", action.intentEvidence)
            lifecycle("Started", action.startedEvidence)
            lifecycle("Outcome", action.outcomeEvidence)
            if action.causalLinks.isEmpty {
                DetailRow(label: "Links", value: "none recorded")
            } else {
                ForEach(Array(action.causalLinks.enumerated()), id: \.offset) { _, link in
                    DetailRow(
                        label: link.kind.rawValue.replacingOccurrences(of: "_", with: " "),
                        value: WorkActionVisuals.label(for: link.target), mono: true)
                }
            }
            if action.omittedCausalLinkCount > 0 {
                let count = action.omittedCausalLinkCountIsLowerBound
                    ? "at least \(action.omittedCausalLinkCount)"
                    : "\(action.omittedCausalLinkCount)"
                DetailRow(
                    label: "Links omitted",
                    value: "\(count) additional typed link record"
                        + "\(action.omittedCausalLinkCount == 1 ? "" : "s") outside this bounded view")
            }
        }
    }

    @ViewBuilder
    private func lifecycle(_ label: String, _ observation: WorkActionObservation?) -> some View {
        if let observation {
            VStack(alignment: .leading, spacing: 2) {
                DetailRow(
                    label: label,
                    value: "#\(observation.sequence.map(String.init) ?? "?") · "
                        + observation.sourceEvent.eventID,
                    mono: true)
                Text(lifecycleDetail(observation))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let cause = observation.causedBy {
                    DetailRow(
                        label: "Caused by",
                        value: cause.journal.stableKey + "/" + cause.eventID,
                        mono: true)
                }
                if let parent = observation.parentActivity {
                    DetailRow(
                        label: "Parent activity",
                        value: parent.journal.stableKey + "/" + parent.eventID,
                        mono: true)
                }
            }
        } else {
            DetailRow(label: label, value: "not recorded")
        }
    }

    private func lifecycleDetail(_ observation: WorkActionObservation) -> String {
        var parts = [
            "\(observation.actor.kind)/\(observation.actor.actorID)",
            Fmt.timestamp(observation.hostRecordedAt),
        ]
        if let run = observation.run { parts.append("Run \(run.runID)") }
        if let turn = observation.turn { parts.append("Turn \(turn.turnID)") }
        parts.append(observation.provenance.rawValue.replacingOccurrences(of: "_", with: " "))
        return parts.joined(separator: " · ")
    }
}

private enum WorkActionVisuals {
    static func tint(for state: ActionExecutionState) -> Color {
        switch state {
        case .succeeded: return Design.success
        case .failed, .indeterminateEffect: return Design.danger
        case .canceled, .cancelRequested: return Design.warning
        case .running, .queued: return Design.accent
        case .proposed, .unknown: return .secondary
        }
    }

    static func label(for target: TimelineEvidenceTarget) -> String {
        switch target {
        case .event(let ref): return ref.journal.stableKey + "/" + ref.eventID
        case .claim(let ref): return "claim " + ref.journal.stableKey + "/" + ref.eventID
        case .artifact(let ref): return "artifact " + ref.referenceID
        }
    }
}
