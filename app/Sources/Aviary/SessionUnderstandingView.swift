import AviaryCore
import SwiftUI

/// Two deliberately separate views of an agent session:
///
/// - recorded model context is what crossed Aviary's provider boundary last time;
/// - canonical working state is what durable Work/Session evidence proves now.
///
/// Neither projection invents the next request or a live Python namespace.
struct RecordedModelContextCard: View {
    let projection: RecordedModelContextProjection
    @State private var showsDetails = false

    var body: some View {
        Card(
            "Recorded model context", symbol: "arrow.up.doc",
            accessory: AnyView(Chip(text: availabilityLabel, tint: availabilityTint))
        ) {
            VStack(alignment: .leading, spacing: 7) {
                Text(availabilityExplanation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(projection.availability == .invalid ? Design.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if projection.availability == .observed {
                    DetailRow(label: "Model", value: projection.modelID ?? "unknown", mono: true)
                    DetailRow(
                        label: "Delivered",
                        value: bytePair(projection.deliveredBytes, cumulative: projection.cumulativeDeliveredBytes),
                        mono: true)
                    DetailRow(
                        label: "Components",
                        value: countLabel(projection.componentCount, omitted: projection.omittedComponentCount))
                    DetailRow(
                        label: "Prompt sources",
                        value: sourceCountLabel)
                    DetailRow(
                        label: "Compaction",
                        value: compactionLabel)
                    if projection.hasOmissions {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Design.warning)
                            Text(omissionSummary)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Design.warning)
                        }
                    }

                    DisclosureGroup(isExpanded: $showsDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let sources = projection.sources {
                                ForEach(sources) { source in
                                    promptSourceRow(source)
                                }
                                if projection.omittedSourceCount > 0 {
                                    boundedNotice("\(projection.omittedSourceCount) additional prompt sources")
                                }
                            } else {
                                boundedNotice("This crossing has no producer-side source decomposition.")
                            }
                            Divider().opacity(0.5)
                            ForEach(projection.components) { component in
                                componentRow(component)
                            }
                            if projection.omittedComponentCount > 0 {
                                boundedNotice("\(projection.omittedComponentCount) additional context components")
                            }
                        }
                        .padding(.top, 7)
                    } label: {
                        Text("Crossing details")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                }
            }
        }
    }

    private var availabilityLabel: String {
        switch projection.availability {
        case .observed: "provider-bound"
        case .unavailable: "not recorded"
        case .invalid: "unavailable"
        }
    }

    private var availabilityTint: Color {
        switch projection.availability {
        case .observed: Design.success
        case .unavailable: .secondary
        case .invalid: Design.warning
        }
    }

    private var availabilityExplanation: String {
        switch projection.availability {
        case .observed:
            "This is the last canonical provider crossing. The next request has not been assembled yet and may differ."
                + " A recorded body address does not prove that body is present on this device."
        case .unavailable:
            "No canonical provider crossing has been recorded for this Session yet."
        case .invalid:
            "Context evidence exists, but its Session projection is not safe to present as model-visible truth."
        }
    }

    private var sourceCountLabel: String {
        guard let count = projection.sourceCount else { return "not decomposed" }
        return countLabel(count, omitted: projection.omittedSourceCount)
    }

    private var compactionLabel: String {
        guard projection.compactionSummaryByteCount != nil
                || projection.compactionSummaryDigest != nil
                || projection.compactionBoundaryEventID != nil else {
            return "not part of this crossing"
        }
        return projection.compactionSummaryInspectionRequired
            ? "component recorded · body address recorded"
            : "component recorded · metadata only"
    }

    private var omissionSummary: String {
        var pieces: [String] = []
        if projection.omissionCount > 0 { pieces.append("\(projection.omissionCount) manifest omission(s)") }
        if projection.omittedComponentCount > 0 { pieces.append("component list bounded") }
        if projection.omittedSourceCount > 0 { pieces.append("source list bounded") }
        if projection.unknowns.eventCount > 0 || projection.unknowns.referenceCount > 0 {
            pieces.append("unknown context evidence")
        }
        return pieces.isEmpty ? "Some context was not delivered in full." : pieces.joined(separator: " · ")
    }

    private func promptSourceRow(_ source: RecordedModelContextSource) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: source.status == .truncated ? "doc.badge.ellipsis" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(source.status == .truncated ? Design.warning : Design.accent)
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(source.label).font(.system(size: 10.5, weight: .medium))
                    Spacer()
                    Text(statusLabel(source.status))
                        .font(Design.mono(9))
                        .foregroundStyle(.secondary)
                }
                Text(sourceSizeLabel(source))
                    .font(Design.mono(9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func componentRow(_ component: RecordedModelContextComponent) -> some View {
        HStack(spacing: 7) {
            Image(systemName: component.bodyReference == nil ? "link.slash" : "link")
                .font(.system(size: 9))
                .foregroundStyle(component.bodyReference == nil ? .secondary : Design.success)
                .frame(width: 13)
            Text(component.mode.rawValue.replacingOccurrences(of: "_", with: " "))
                .font(.system(size: 10.5))
            Spacer()
            Text(componentSizeLabel(component))
                .font(Design.mono(9.5))
                .foregroundStyle(component.omitted ? Design.warning : .secondary)
        }
    }

    private func componentSizeLabel(_ component: RecordedModelContextComponent) -> String {
        let bytes = component.deliveredBytes.map(Fmt.bytes) ?? "unknown"
        return "\(bytes) · \(component.deliveryMode.rawValue)"
    }

    private func sourceSizeLabel(_ source: RecordedModelContextSource) -> String {
        let delivered = Fmt.bytes(source.deliveredByteCount)
        let address = source.deliveredBodyReference == nil ? "metadata only" : "address recorded"
        guard let full = source.fullByteCount else {
            return "\(delivered) delivered · full size unknown · \(address)"
        }
        return "\(delivered) delivered / \(Fmt.bytes(full)) full · \(address)"
    }

    private func bytePair(_ delivered: Int?, cumulative: Int?) -> String {
        let current = delivered.map(Fmt.bytes) ?? "unknown"
        guard let cumulative else { return current }
        return "\(current) this crossing · \(Fmt.bytes(cumulative)) this Run"
    }

    private func countLabel(_ count: Int, omitted: Int) -> String {
        omitted == 0 ? "\(count)" : "\(count) total · \(omitted) not shown"
    }

    private func statusLabel(_ status: PromptSourceStatus) -> String {
        status.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private func boundedNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CanonicalWorkingStateCard: View {
    let projection: CanonicalWorkingStateProjection
    @State private var showsRecovery = false

    var body: some View {
        Card(
            "Canonical working state", symbol: "server.rack",
            accessory: AnyView(Chip(
                text: projection.isCanonical ? "exact cursors" : "incomplete",
                tint: projection.isCanonical ? Design.success : Design.warning))
        ) {
            VStack(alignment: .leading, spacing: 7) {
                Text(
                    "Durable Work and Session facts are separate from live runtime objects. "
                        + namespaceExplanation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(projection.isCanonical ? .secondary : Design.warning)
                    .fixedSize(horizontal: false, vertical: true)

                DetailRow(
                    label: "Cursor",
                    value: "Work #\(projection.workCursor.sequence) · Session #\(projection.sessionCursor.sequence)",
                    mono: true)
                if projection.isCanonical {
                    DetailRow(
                        label: "Lifecycle",
                        value: "\(projection.lifecycle.rawValue) · \(projection.execution.rawValue)")
                    DetailRow(label: "Run", value: projection.currentRun == nil ? "none active" : "active")
                    DetailRow(label: "Turn", value: projection.activeTurn == nil ? "none active" : "active")
                    DetailRow(label: "Runtime namespace", value: namespaceLabel, tint: namespaceTint)

                    HStack(spacing: 8) {
                        stateCount("actions", projection.actions.count, omitted: projection.omittedActionCount)
                        stateCount("handles", projection.handles.count, omitted: projection.omittedHandleCount)
                        stateCount("children", projection.children.count, omitted: projection.omittedChildCount)
                        stateCount(
                            "artifacts", projection.artifacts.count,
                            omitted: projection.omittedArtifactCount,
                            partial: projection.artifactIndexCompleteness != .complete)
                    }

                    if projection.artifactIndexCompleteness != .complete {
                        DetailRow(
                            label: "Artifact index",
                            value: artifactIndexExplanation, tint: Design.warning)
                    }
                    if projection.attachmentIndexCompleteness != .complete {
                        DetailRow(
                            label: "Attachment index",
                            value: "selected relationship proved · \(projection.omittedAttachmentCount) other rows omitted",
                            tint: Design.warning)
                    }
                    if projection.unclassifiedDescriptorOmissionCount > 0 {
                        DetailRow(
                            label: "Other descriptor data",
                            value: "unknown completeness · \(projection.unclassifiedDescriptorOmissionCount) values omitted",
                            tint: Design.warning)
                    }

                    if !projection.recovery.isEmpty {
                        DisclosureGroup(isExpanded: $showsRecovery) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(projection.recovery.enumerated()), id: \.offset) {
                                    _, claim in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(recoveryOperationLabel(claim.operation))
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(
                                            "\(claim.source == .workJournal ? "Work" : "Session") evidence"
                                                + " · Session attachment \(shortIdentity(claim.sessionAttachmentID))"
                                                + " · Run \(shortIdentity(claim.runID))"
                                        )
                                            .font(Design.mono(9))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                        ForEach(RecoveryPlane.allCases, id: \.self) { plane in
                                            DetailRow(
                                                label: recoveryPlaneLabel(plane),
                                                value: recoveryStatus(claim, plane: plane))
                                        }
                                    }
                                }
                                if projection.omittedRecoveryCount > 0 {
                                    Text(
                                        "\(projection.omittedRecoveryCount) additional recovery claims are not shown "
                                            + "(Work \(projection.omittedWorkRecoveryCount), "
                                            + "Session \(projection.omittedSessionRecoveryCount)).")
                                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.top, 7)
                        } label: {
                            Text("Recovery coverage")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                    }
                } else {
                    DetailRow(
                        label: "Work source", value: projection.workSourceCompleteness.rawValue)
                    DetailRow(
                        label: "Session source", value: projection.sessionSourceCompleteness.rawValue)
                    Text("Derived lifecycle, model, action, Handle, artifact, recovery, and namespace facts are withheld.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Design.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    if !projection.canonicalityFailures.isEmpty {
                        Text(
                            projection.canonicalityFailures
                                .map { $0.rawValue.replacingOccurrences(of: "_", with: " ") }
                                .joined(separator: " · "))
                            .font(Design.mono(9))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(
                                "Canonicality checks failed: "
                                    + projection.canonicalityFailures
                                        .map(\.rawValue).joined(separator: ", "))
                    }
                }
            }
        }
    }

    private var namespaceLabel: String {
        switch projection.namespace.availability {
        case .live: "live metadata · \(projection.namespace.totalBindingCount) bindings"
        case .reconnectable: "live host can be reattached"
        case .unavailable: "unavailable"
        case .notReconstructed: "not reconstructed"
        case .notExposed: "not exposed by this Work Host"
        }
    }

    private var namespaceExplanation: String {
        switch projection.namespace.availability {
        case .live: "Namespace metadata is live; values still require explicit inspection."
        case .reconnectable: "A host reattachment can recover namespace metadata."
        case .unavailable: "The namespace is unavailable."
        case .notReconstructed: "Conversation recovery did not reconstruct the namespace."
        case .notExposed: "This Work Host does not expose namespace inspection to the GUI."
        }
    }

    private var namespaceTint: Color? {
        switch projection.namespace.availability {
        case .live, .reconnectable: Design.success
        case .notExposed: .secondary
        case .unavailable, .notReconstructed: Design.warning
        }
    }

    private func stateCount(
        _ label: String, _ count: Int, omitted: Int, partial: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(Design.numeric(16, weight: .semibold))
            Text(
                label + (omitted > 0 ? " +\(omitted)" : "")
                    + (partial ? " · partial" : ""))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artifactIndexExplanation: String {
        var parts: [String] = []
        if projection.artifactIndexCompleteness == .unknown {
            parts.append("enumeration unavailable")
        }
        if projection.omittedArtifactCount > 0 {
            parts.append("\(projection.omittedArtifactCount) rows omitted")
        }
        if projection.omittedArtifactMetadataCount > 0 {
            parts.append("\(projection.omittedArtifactMetadataCount) metadata values omitted")
        }
        return parts.isEmpty ? "partial" : parts.joined(separator: " · ")
    }

    private func shortIdentity(_ value: String) -> String {
        String(value.suffix(8))
    }

    private func recoveryStatus(
        _ claim: CanonicalWorkingRecovery, plane: RecoveryPlane
    ) -> String {
        guard let status = claim.planes[plane] else { return "unknown" }
        return status.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private func recoveryOperationLabel(_ operation: RecoveryOperation) -> String {
        operation.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private func recoveryPlaneLabel(_ plane: RecoveryPlane) -> String {
        switch plane {
        case .timeline: "Timeline"
        case .effectiveContext: "Model context"
        case .runtimeNamespace: "Namespace"
        case .backgroundWork: "Background work"
        case .memoriesArtifactsRepository: "Memory / files"
        case .externalEffects: "External effects"
        }
    }
}
