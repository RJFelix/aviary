import AviaryCore
import SwiftUI

private enum WorkActionCopy {
    static func kindTitle(_ kind: ActionKind) -> String {
        switch kind {
        case .provider: return "Model"
        case .compactionProvider: return "Conversation summary"
        case .providerSetup: return "Model setup"
        case .python: return "Python step"
        case .mcp: return "Integration"
        case .runtime: return "Runtime step"
        case .hook: return "Automation hook"
        case .peerDelivery: return "Message to another agent"
        case .selfDelivery: return "Session notification"
        case .webSearch: return "Web search"
        case .webExtract: return "Read web content"
        case .child: return "Child agent"
        case .memory: return "Memory note"
        case .artifact: return "Saved artifact"
        case .imageRead: return "Read image"
        case .nestedProcessCallback: return "Nested Work callback"
        case .directShell: return "Command"
        }
    }

    static func activityTitle(for action: WorkActionPresentation) -> String {
        guard let intent = action.intent else {
            return kindTitle(action.kind)
        }
        switch intent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "request the next agent response":
            return "Generate the next response"
        case "compact the conversation with the provider":
            return "Summarize the conversation"
        case "execute one python cell":
            return "Run a Python step"
        case "call an mcp tool":
            return "Use an integration"
        case "start a child agent":
            return "Start a child agent"
        case "write a memory entry":
            return "Save a memory note"
        case "write an artifact":
            return "Save an artifact"
        case "read an image for the model":
            return "Read an image"
        default:
            return action.kind == .directShell ? "Run command" : intent
        }
    }

    static func statusTitle(_ state: ActionExecutionState) -> String {
        switch state {
        case .unknown: return "Status unknown"
        case .proposed: return "Preparing"
        case .queued: return "Waiting"
        case .running: return "In progress"
        case .cancelRequested: return "Stopping"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        case .indeterminateEffect: return "Outcome unclear"
        }
    }
}

private struct WorkActionStatusBadge: View {
    let state: ActionExecutionState
    var isCurrent: Bool = true

    private var tint: Color { isCurrent ? WorkActionVisuals.tint(for: state) : .secondary }

    var body: some View {
        Label(stateTitle, systemImage: WorkActionVisuals.statusSymbol(for: state))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
            )
            .accessibilityLabel(stateTitle)
    }

    private var stateTitle: String {
        WorkActionCopy.statusTitle(state)
    }
}

/// The primary surface reports only recorded activity. Missing intent, timing, causality, and
/// speculative next steps belong in the evidence view, not in three permanent warning columns.
struct WorkActivityStrip: View {
    let action: WorkActionPresentation
    let concurrentActions: [WorkActionPresentation]
    var sourceIsCurrent: Bool = true
    let onInspect: (WorkActionPresentation) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                summary.frame(minWidth: 260)
                inspectionControl
            }
            VStack(alignment: .leading, spacing: 8) {
                summary
                inspectionControl.padding(.leading, 15)
            }
        }
        .padding(.horizontal, Design.gutter).padding(.vertical, 10)
        .background(Design.accent.opacity(0.055))
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: WorkActionVisuals.symbol(for: action.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(sourceIsCurrent ? Design.accent : .secondary)
                .frame(width: 32, height: 32)
                .background(Design.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottomTrailing) {
                    if sourceIsCurrent && action.state == .running {
                        PulseDot(color: WorkActionVisuals.tint(for: action.state))
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(activityTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(sourceIsCurrent ? WorkActionCopy.kindTitle(action.kind)
                        : "Last recorded activity")
                    Text("·")
                    WorkActionStatusBadge(state: action.state, isCurrent: sourceIsCurrent)
                    if concurrentActions.count > 1 {
                        Text("· \(concurrentActions.count) steps in progress or waiting")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var activityTitle: String {
        if action.kind == .provider && action.state == .running {
            return "Generating a response"
        }
        return WorkActionCopy.activityTitle(for: action)
    }

    @ViewBuilder private var inspectionControl: some View {
        if concurrentActions.count > 1 {
            Menu {
                ForEach(concurrentActions) { candidate in
                    Button(menuLabel(candidate)) {
                        onInspect(candidate)
                    }
                }
            } label: {
                Label("Activity details", systemImage: "list.bullet")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Inspect steps in progress or waiting")
        } else {
            Button {
                onInspect(action)
            } label: {
                Label("View activity details", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel(
                "View activity details for \(WorkActionCopy.activityTitle(for: action))")
        }
    }

    private func menuLabel(_ candidate: WorkActionPresentation) -> String {
        let subject = String(WorkActionCopy.activityTitle(for: candidate)
            .replacingOccurrences(of: "\n", with: " ").prefix(64))
        return "\(subject) · \(WorkActionCopy.statusTitle(candidate.state)) "
            + "· …\(candidate.id.suffix(8))"
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
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !activity.sourceIsComplete {
                Label("Last recorded activity · this view may be stale or incomplete",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Design.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            actionSection(
                activity.sourceIsComplete ? "In progress" : "Last recorded as unsettled",
                symbol: "clock.arrow.circlepath", tint: Design.accent,
                subtitle: "Includes steps waiting to start, running, or waiting for cancellation. "
                    + "These are the latest recorded states, not a separate live-process check.",
                actions: activity.current)
            actionSection(
                "Needs review", symbol: "exclamationmark.triangle.fill", tint: Design.danger,
                subtitle: "Failures and unclear outcomes stay visible so you can review them. "
                    + "They do not by themselves mean the agent is blocked or safe to retry.",
                actions: activity.problems)
            actionSection("Completed", symbol: "checkmark.circle.fill", tint: Design.success,
                          subtitle: "Finished steps, including canceled ones. Open a step's details before assuming an external effect completed.",
                          actions: activity.completed)
            if activity.omittedCount > 0 {
                Label("\(activity.omittedCount) additional action records are outside this view.",
                      systemImage: "ellipsis.circle")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            backgroundActivity
        }
    }

    @ViewBuilder
    private var backgroundActivity: some View {
        if children.hasRecords || !children.isAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Label("Child agents", systemImage: "person.2")
                    .font(.system(size: 13, weight: .semibold))
                Text(children.summary).font(.system(size: 11.5))
                DisclosureGroup {
                    Text(children.disclosure)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Label("About child-agent activity", systemImage: "questionmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }
        if let agentHandles, agentHandles.hasRecords || !agentHandles.isAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Label("Background agents", systemImage: "person.2.wave.2")
                    .font(.system(size: 13, weight: .semibold))
                Text(agentHandles.summary).font(.system(size: 11.5))
                ForEach(Array(agentHandles.rows.enumerated()), id: \.element.id) { index, row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Background agent \(index + 1) · \(row.statusTitle)")
                            .font(.system(size: 12, weight: .medium))
                        Text(row.policySummary).font(.system(size: 11)).foregroundStyle(.secondary)
                        if let deadline = row.deadline {
                            Text("Deadline: \(deadline.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !agentHandles.rows.isEmpty {
                    Text("Token and cost thresholds stop the next model request; an in-flight request may exceed them.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DisclosureGroup {
                    Text(agentHandles.disclosure)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Label("About background-agent activity", systemImage: "questionmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    @ViewBuilder
    private func actionSection(
        _ title: String, symbol: String, tint: Color, subtitle: String,
        actions: [WorkActionPresentation]
    ) -> some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ActionSectionHeading(title: title, symbol: symbol, tint: tint,
                                     count: actions.count, explanation: subtitle)
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

private struct ActionSectionHeading: View {
    let title: String
    let symbol: String
    let tint: Color
    let count: Int
    let explanation: String
    @State private var showsExplanation = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint).accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text("\(count)").font(Design.numeric(11, weight: .semibold))
                .foregroundStyle(tint).padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
                .accessibilityLabel("\(count) in view")
            Spacer(minLength: 4)
            Button { showsExplanation.toggle() } label: {
                Image(systemName: "info.circle").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("About \(title.lowercased())")
            .help(explanation)
            .popover(isPresented: $showsExplanation) {
                Text(explanation).font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true).padding(16).frame(width: 300)
            }
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
                    Image(systemName: WorkActionVisuals.symbol(for: action.kind))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkActionCopy.activityTitle(for: action))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(WorkActionCopy.kindTitle(action.kind))
                            WorkActionStatusBadge(state: action.state)
                            if let duration = action.durationSeconds {
                                Text(Fmt.duration(duration))
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        if let target = action.affectedTarget {
                            Label(target, systemImage: "scope")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work-action-\(action.actionID)")
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides the recorded activity details")

            if let retry = action.retryGuidance,
               expanded || action.state == .failed || action.state == .indeterminateEffect,
               action.retrySafety == .unsafe || action.retrySafety == .unknown
                    || action.retrySafety == nil || action.state == .indeterminateEffect {
                Label(retry, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(action.state == .indeterminateEffect ? Design.danger : Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    DetailRow(label: "Intent", value: action.intent ?? "not recorded")
                    DetailRow(label: "Could affect", value: action.affectedTarget ?? "not recorded")
                    DetailRow(label: "Scope", value: action.scope ?? "not recorded")
                    WorkActionEvidenceDetails(action: action)
                }.padding(.leading, 18)
            }
        }
        .padding(.vertical, 3)
    }

    private var tint: Color { WorkActionVisuals.tint(for: action.state) }

    private var accessibilitySummary: String {
        var parts = [
            WorkActionCopy.kindTitle(action.kind), WorkActionCopy.statusTitle(action.state)
        ]
        parts.insert(WorkActionCopy.activityTitle(for: action), at: 0)
        if let target = action.affectedTarget { parts.append("Target \(target)") }
        return parts.joined(separator: ", ")
    }
}

struct WorkActionDetailSheet: View {
    let action: WorkActionPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var showsTechnicalDetails = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(WorkActionVisuals.tint(for: action.state))
                    .frame(width: 8, height: 8)
                Text(WorkActionCopy.kindTitle(action.kind))
                    .font(.system(size: 14, weight: .semibold))
                Chip(text: WorkActionCopy.statusTitle(action.state),
                     tint: WorkActionVisuals.tint(for: action.state))
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
                    Card("Activity", symbol: "bolt.horizontal.circle") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(WorkActionCopy.activityTitle(for: action))
                                .font(.body).textSelection(.enabled)
                            if let intent = action.intent,
                               intent != WorkActionCopy.activityTitle(for: action) {
                                DetailRow(label: "Recorded request", value: intent)
                            }
                            if let target = action.affectedTarget {
                                DetailRow(label: "Target", value: target, mono: true)
                            }
                            if let scope = action.scope { DetailRow(label: "Scope", value: scope) }
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
                    Button { showsTechnicalDetails.toggle() } label: {
                        HStack {
                            Image(systemName: showsTechnicalDetails ? "chevron.down" : "chevron.right")
                            Text("Technical details")
                            Spacer()
                        }
                        .padding(10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsTechnicalDetails ? "Expanded" : "Collapsed")
                    if showsTechnicalDetails {
                    Card("Limits of this view", symbol: "scope") {
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
                    Card("Journal references", symbol: "link") {
                        WorkActionEvidenceDetails(action: action)
                    }
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
                Label("Activity no longer in view", systemImage: "ellipsis.circle")
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

    static func statusSymbol(for state: ActionExecutionState) -> String {
        switch state {
        case .unknown: return "questionmark.circle"
        case .proposed: return "ellipsis.circle"
        case .queued: return "clock"
        case .running: return "play.circle.fill"
        case .cancelRequested: return "stop.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .canceled: return "stop.circle.fill"
        case .indeterminateEffect: return "questionmark.diamond.fill"
        }
    }

    static func symbol(for kind: ActionKind) -> String {
        switch kind {
        case .provider: return "cloud.fill"
        case .compactionProvider: return "arrow.down.right.and.arrow.up.left"
        case .providerSetup: return "key.fill"
        case .python, .directShell: return "terminal.fill"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .runtime: return "gearshape.2.fill"
        case .hook: return "line.3.horizontal.decrease.circle"
        case .peerDelivery: return "arrow.up.forward.circle"
        case .selfDelivery: return "arrow.turn.down.left"
        case .webSearch: return "magnifyingglass"
        case .webExtract: return "doc.text.magnifyingglass"
        case .child: return "person.2.fill"
        case .memory: return "brain.head.profile"
        case .artifact: return "shippingbox.fill"
        case .imageRead: return "photo"
        case .nestedProcessCallback: return "arrow.triangle.branch"
        }
    }
}
