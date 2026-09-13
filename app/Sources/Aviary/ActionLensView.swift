import AviaryCore
import SwiftUI

/// The primary surface reports only recorded activity. Missing intent, timing, causality, and
/// speculative next steps belong in the evidence view, not in three permanent warning columns.
struct WorkActivityStrip: View {
    let action: WorkActionPresentation
    let concurrentActions: [WorkActionPresentation]
    var sourceIsCurrent: Bool = true
    let onInspect: (WorkActionPresentation) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if sourceIsCurrent && action.state == .running {
                    PulseDot(color: WorkActionVisuals.tint(for: action.state))
                } else {
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                }
            }.padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.intent ?? action.kindTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(sourceIsCurrent ? action.kindTitle : "Last recorded activity")
                    Text("·")
                    Text(action.stateTitle)
                    if concurrentActions.count > 1 {
                        Text("· \(concurrentActions.count) unsettled in view")
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
                    Text("Current steps and recorded outcomes")
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
                    ChatActivityContent(
                        activity: run.chatActivity,
                        children: run.childActivity,
                        agentHandles: run.isServiceBacked
                            ? ChatAgentHandleActivityPresentation(
                                workingState: run.canonicalWorkingState,
                                sourceIsCurrent: run.serviceActivitySourceIsCurrent)
                            : nil)
                }.padding(16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent activity")
        .frame(minWidth: 420, idealWidth: 640, minHeight: 420, idealHeight: 660)
    }
}

/// Shared by the live sheet and deterministic visual fixtures; every row is prepared in Core.
struct ChatActivityContent: View {
    let activity: ChatActivityPresentation
    let children: ChatChildActivityPresentation
    /// Optional keeps deterministic activity fixtures focused on their legacy child records;
    /// service-backed callers pass the distinct Work-owned Handle presentation explicitly.
    var agentHandles: ChatAgentHandleActivityPresentation? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(activity.summary)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !activity.sourceIsComplete {
                Label("Recorded view only · some activity may be unavailable or out of date",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if children.hasRecords || !children.isAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Recorded child agents", systemImage: "person.2")
                        .font(.system(size: 12, weight: .semibold))
                    Text(children.summary).font(.system(size: 12))
                    Text(children.disclosure).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }
            if let agentHandles, agentHandles.hasRecords || !agentHandles.isAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Recorded background agents", systemImage: "person.2.wave.2")
                        .font(.system(size: 12, weight: .semibold))
                    Text(agentHandles.summary).font(.system(size: 12))
                    ForEach(Array(agentHandles.rows.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Background agent \(index + 1) · \(row.statusTitle)")
                                .font(.system(size: 11, weight: .medium))
                            Text(row.policySummary).font(.caption).foregroundStyle(.secondary)
                            if let deadline = row.deadline {
                                Text("Deadline: \(deadline.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !agentHandles.rows.isEmpty {
                        Text("Token and cost thresholds stop the next model request; an in-flight request may exceed them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(agentHandles.disclosure).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }
            actionSection(
                activity.sourceIsComplete ? "In progress" : "Last recorded as unsettled",
                subtitle: "Includes queued, proposed, and cancellation-requested steps; not every step is executing.",
                actions: activity.current)
            actionSection(
                "Recorded problems",
                subtitle: "Past failures or uncertain effects. These do not by themselves mean the agent is blocked or that you should retry.",
                actions: activity.problems)
            actionSection("Completed", subtitle: "Recorded outcomes, including canceled steps.",
                          actions: activity.completed)
            if activity.omittedCount > 0 {
                Text("\(activity.omittedCount) additional action records are outside this view.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionSection(
        _ title: String, subtitle: String, actions: [WorkActionPresentation]
    ) -> some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text("\(actions.count) in view").font(.caption).foregroundStyle(.secondary)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(actions) { action in
                    WorkActionLensRow(action: action)
                    Divider()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
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
