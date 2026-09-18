import SwiftUI
import AviaryCore

/// Read-only presentation of the bounded repository review artifact. The production initializer
/// starts empty on purpose: the descriptor is metadata, while body bytes are fetched and parsed
/// only after the person presses Load review.
struct RepositoryReviewView: View {
    private static let maximumComposerBytes = 4_000
    private static let maximumFeedbackBytes = 2_000

    private enum LoadState {
        case ready
        case loading
        case loaded(ObservedRepositoryReview, RepositoryReviewDiffProjection?)
        case failed(RepositoryReviewLoadError)
    }

    private struct ReviewDraft {
        var feedback = ""
        var anchor: RepositoryReviewFeedbackAnchor?
    }

    private let run: LiveRun?
    @State private var selectedDescriptor: WorkServiceArtifactDescriptor?
    private let fixtureRetryEnabled: Bool
    @State private var state: LoadState
    @State private var feedback = ""
    @State private var selectedAnchor: RepositoryReviewFeedbackAnchor?
    @State private var pendingAnchor: RepositoryReviewFeedbackAnchor?
    @State private var drafts: [WorkServiceArtifactDescriptor: ReviewDraft] = [:]
    @State private var placedInComposer = false
    @State private var placedFeedbackCount = 0
    @State private var loadIdentity: UUID?
    @State private var showReviewLimits = false
    @State private var feedbackScrollRequest = 0
    @FocusState private var feedbackFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(run: LiveRun, descriptor: WorkServiceArtifactDescriptor? = nil) {
        self.run = run
        _selectedDescriptor = State(initialValue: descriptor ?? run.serviceReviewDescriptor)
        self.fixtureRetryEnabled = false
        _state = State(initialValue: .ready)
    }

    /// Deterministic fixture entry point. Production views never use a preloaded review; this
    /// lets the snapshot harness render the same sheet content without a Work Host.
    init(
        fixtureReview: ObservedRepositoryReview,
        fixtureDraft: String? = nil,
        fixtureDescriptor: WorkServiceArtifactDescriptor? = nil
    ) {
        self.run = fixtureDraft.map {
            LiveRun.productionRunPaneVisualFixture(
                items: [], pendingInputs: [], deliveryAttention: [], actions: [], draft: $0)
        }
        _selectedDescriptor = State(initialValue: fixtureDescriptor)
        self.fixtureRetryEnabled = false
        let projection = fixtureDescriptor.flatMap {
            try? RepositoryReviewDiffProjection.prepare(review: fixtureReview, descriptor: $0)
        }
        _state = State(initialValue: .loaded(fixtureReview, projection))
    }

    /// Deterministic stale-state entry point for the snapshot harness. Production retry always
    /// reads the current LiveRun descriptor; this route only exercises the safe failure copy.
    init(fixtureError error: RepositoryReviewLoadError, allowsRetry: Bool = false) {
        self.run = nil
        _selectedDescriptor = State(initialValue: nil)
        self.fixtureRetryEnabled = allowsRetry
        _state = State(initialValue: .failed(error))
    }

    private var reviewRows: [WorkServiceRepositoryReviewHistoryRow] {
        guard let history = run?.serviceReviewHistory, history.sourceComplete else { return [] }
        return history.rows
    }

    private var selectedIsAvailable: Bool {
        guard let selectedDescriptor else { return false }
        return reviewRows.contains { $0.descriptor == selectedDescriptor }
    }

    private var selectedIsLoadable: Bool {
        selectedIsAvailable && selectedDescriptor?.available == true
            && selectedDescriptor?.bodyReference != nil
            && run?.serviceProjection?.capabilities.contains(.inspectArtifacts) == true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if run?.isServiceBacked == true { historyPicker }
                        boundaryNotice
                        switch state {
                        case .ready:
                            loadPrompt
                        case .loading:
                            loadingView
                        case .loaded(let review, let projection):
                            reviewBody(review, projection: projection)
                        case .failed(let error):
                            failureView(error)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: feedbackScrollRequest) { _, _ in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo("repository-review-feedback", anchor: .center)
                    }
                    Task { @MainActor in feedbackFocused = true }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository review")
        .onChange(of: run?.serviceReviewHistory) { _, _ in
            historyDidChange()
        }
        .onChange(of: feedback) { _, _ in
            persistCurrentDraft()
            placedInComposer = false
            placedFeedbackCount = 0
        }
        .confirmationDialog(
            "Move this feedback?",
            isPresented: Binding(
                get: { pendingAnchor != nil },
                set: { if !$0 { pendingAnchor = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move feedback") { moveFeedbackToPendingAnchor() }
            Button("Keep editing", role: .cancel) { pendingAnchor = nil }
        } message: {
            if let pendingAnchor {
                Text("Move the current draft from \(anchorLabel(selectedAnchor)) to \(anchorLabel(pendingAnchor))?")
            }
        }
        .onDisappear { loadIdentity = nil }
    }

    private var historyPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Saved observations", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("\(reviewRows.count) recorded")
                    .font(Design.numeric(10)).foregroundStyle(.secondary)
            }
            Picker("Review", selection: Binding(
                get: { selectedDescriptor },
                set: { descriptor in
                    guard let descriptor, reviewRows.contains(where: {
                        $0.descriptor == descriptor
                    }) else { return }
                    selectReview(descriptor)
                }
            )) {
                if !selectedIsAvailable {
                    Text("Selected review unavailable")
                        .tag(selectedDescriptor)
                }
                ForEach(Array(reviewRows.enumerated()), id: \.element.descriptor) { index, row in
                    Text(reviewPickerLabel(index: index, descriptor: row.descriptor))
                        .tag(Optional(row.descriptor))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("Saved review selection")
            Text("Ordered by publication. Each review records the working tree at that time, not the difference from the preceding review.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let omitted = run?.serviceReviewHistory?.omittedRowCount, omitted > 0 {
                Text("\(omitted) review records are unavailable or outside this bounded list.")
                    .font(.caption).foregroundStyle(Design.warning)
            }
            if !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || selectedAnchor != nil {
                Label("Draft kept while this review is open", systemImage: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(Design.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review changes")
                    .font(.system(size: 14, weight: .semibold))
                Text("A saved view of the working tree")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var boundaryNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Label(
                    "Working-tree changes, not just the agent's edits",
                    systemImage: "eye")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Design.accent)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Chip(text: "read only", symbol: "lock.fill", tint: Design.accent)
            }
            Text("This saved review can include your edits and other work. Reading it does not change any files.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("What this review covers", isExpanded: $showReviewLimits) {
                Text("Changes are relative to the recorded Git HEAD, at the time shown below. "
                    + "This is not a checkpoint or proof that the task is correct. "
                    + "File contents may include sensitive values or paths. "
                    + "Aviary does not stage, revert, or commit anything from this view.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.caption)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.accent.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Design.accent.opacity(0.25), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var loadPrompt: some View {
        Card("Recorded project state", symbol: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    selectedDescriptor == nil
                        ? "A matching review artifact is no longer available."
                        : "Inspect the recorded working tree and any diffs, then prepare feedback for the agent. The project may be unchanged; existing edits are not necessarily from this turn."
                )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Diffs show file contents, which may include sensitive values or paths.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let selectedDescriptor {
                    HStack(spacing: 8) {
                        Chip(text: selectedDescriptor.available ? "available" : "unavailable",
                             tint: selectedDescriptor.available ? Design.success : Design.warning)
                        Text("saved review")
                            .font(Design.mono(9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Button("Inspect project state") {
                    loadReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(run == nil || !selectedIsLoadable)
                .accessibilityHint("Fetches and validates the selected review artifact")
            }
        }
    }

    private var loadingView: some View {
        Card("Loading review", symbol: "arrow.triangle.2.circlepath") {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the current artifact identity and reading a bounded body…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func failureView(_ error: RepositoryReviewLoadError) -> some View {
        let detail: (title: String, message: String, tint: Color, symbol: String) = switch error {
        case .stale:
            (
                "Review is stale",
                "The canonical Work projection changed while this observation was loading. Load it again to inspect a new, verified point in time.",
                Design.warning,
                "arrow.triangle.2.circlepath"
            )
        case .unavailable:
            (
                "Review unavailable",
                "The selected artifact disappeared, changed identity, or could not be verified. No stale content was shown.",
                Design.danger,
                "exclamationmark.triangle"
            )
        case .bounded:
            (
                "Review exceeds the display bound",
                "The artifact is larger than Aviary's bounded review read. Nothing outside the bound was loaded.",
                Design.warning,
                "arrow.down.right.and.arrow.up.left"
            )
        }
        return Card(detail.title, symbol: detail.symbol) {
            VStack(alignment: .leading, spacing: 9) {
                Text(detail.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Try again") { loadReview() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(detail.tint)
                        .disabled(
                            (run == nil && !fixtureRetryEnabled)
                                || (run != nil && !selectedIsLoadable))
                    Chip(text: "no content shown", tint: detail.tint)
                }
            }
        }
    }

    @ViewBuilder
    private func reviewBody(
        _ review: ObservedRepositoryReview,
        projection: RepositoryReviewDiffProjection?
    ) -> some View {
        reviewSummaryCard(review)
        diffsCard(review, projection: projection)
        filesCard(review)
        statusCard(review)
        omissionsCard(review)
        feedbackCard
    }

    private func reviewSummaryCard(_ review: ObservedRepositoryReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusTint(review.status))
                    .frame(width: 26, height: 26)
                    .background(statusTint(review.status).opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.status == .changes ? "Changes ready to inspect" : statusLabel(review.status).capitalized)
                        .font(.system(size: 14, weight: .semibold))
                    Text("A bounded, saved observation of the working tree")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Chip(text: statusLabel(review.status), tint: statusTint(review.status), filled: true)
            }
            HStack(spacing: 8) {
                reviewMetric("FILES", "\(review.files.count)", symbol: "doc")
                reviewMetric("PATCHES", "\(review.diffs.count)", symbol: "arrow.left.arrow.right")
            }
            if review.coverage.bounded || !review.omissions.isEmpty {
                Label("Partial observation · see coverage limits below", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Design.warning)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            statusTint(review.status).opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(statusTint(review.status).opacity(0.22), lineWidth: 1))
    }

    private func reviewMetric(_ label: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Design.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(Design.numeric(13, weight: .semibold))
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.35)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func diffSymbol(_ kind: String) -> String {
        kind == "staged" ? "square.and.arrow.down" : "pencil"
    }

    private func diffTint(_ kind: String) -> Color {
        kind == "staged" ? Design.accent : Design.assistant
    }

    private func statusCard(_ review: ObservedRepositoryReview) -> some View {
        Card("Observation", symbol: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Chip(text: statusLabel(review.status), tint: statusTint(review.status))
                    Text("observed \(Fmt.timestamp(review.observedAt))")
                        .font(Design.numeric(9.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                DetailRow(label: "HEAD", value: sanitized(review.head?.oid ?? "unavailable"), mono: true)
                DetailRow(label: "Ref", value: sanitized(review.head?.ref ?? (review.head?.detached == true ? "detached" : "unavailable")), mono: true)
                DetailRow(label: "Files", value: "\(review.files.count)", mono: true)
                if review.coverage.bounded {
                    Label(
                        "This observation reached one or more configured bounds.",
                        systemImage: "ellipsis.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Design.warning)
                }
            }
        }
    }

    private func filesCard(_ review: ObservedRepositoryReview) -> some View {
        Card("Files and status", symbol: "list.bullet.rectangle") {
            if review.files.isEmpty {
                Text("No file entries were retained.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Repository-relative paths · status pair is index / working tree")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(review.files, id: \.path) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: fileSymbol(file))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(fileTint(file))
                                Text(sanitized(file.path))
                                    .font(Design.mono(10))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .layoutPriority(1)
                                    .textSelection(.enabled)
                            }
                            HStack(spacing: 5) {
                                Chip(
                                    text: statusPair(file),
                                    symbol: "square.split.2x2",
                                    tint: fileTint(file))
                                Text(file.kind)
                                if let originalPath = file.originalPath {
                                    Text("from \(sanitized(originalPath))")
                                }
                                if file.isUntracked { Chip(text: "untracked", tint: Design.warning) }
                                if file.isIgnored { Chip(text: "ignored", tint: .secondary) }
                                if file.isBinary { Chip(text: "binary", tint: Design.warning) }
                                if file.isSubmodule { Chip(text: "submodule", tint: Design.warning) }
                            }
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.028))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
    }

    private func fileSymbol(_ file: ObservedRepositoryFile) -> String {
        if file.isBinary { return "doc.zipper" }
        if file.isSubmodule { return "shippingbox" }
        if file.isUntracked { return "plus.circle" }
        if file.isIgnored { return "eye.slash" }
        return "doc.text"
    }

    private func fileTint(_ file: ObservedRepositoryFile) -> Color {
        if file.isBinary || file.isSubmodule || file.isUntracked {
            return Design.warning
        }
        if file.isIgnored { return .secondary }
        return Design.accent
    }

    @ViewBuilder
    private func diffsCard(
        _ review: ObservedRepositoryReview,
        projection: RepositoryReviewDiffProjection?
    ) -> some View {
        Card("Unified diffs", symbol: "arrow.left.arrow.right") {
            Label(
                "Comment beside a file or hunk to keep feedback attached to this exact observation.",
                systemImage: "text.badge.plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let projection,
               !projection.sections.isEmpty || !projection.rawFallbacks.isEmpty
                    || !projection.omissions.isEmpty {
                projectedDiffs(projection)
            } else if review.diffs.isEmpty {
                Text("No tracked diff body was retained.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else if let projection {
                projectedDiffs(projection)
            } else {
                rawDiffs(review)
            }
        }
    }

    @ViewBuilder
    private func projectedDiffs(_ projection: RepositoryReviewDiffProjection) -> some View {
        let visibleSections = projection.sections.filter {
            $0.fallbackReason == nil || $0.kind == .binary || $0.kind == .submodule
        }
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(visibleSections.enumerated()), id: \.offset) { _, section in
                projectedSection(section, identity: projection.identity)
            }
            ForEach(Array(projection.rawFallbacks.enumerated()), id: \.offset) { _, fallback in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Chip(
                            text: fallback.diffKind.capitalized,
                            symbol: diffSymbol(fallback.diffKind),
                            tint: diffTint(fallback.diffKind))
                        Chip(text: "raw fallback", tint: Design.warning)
                        Spacer(minLength: 4)
                    }
                    Text(fallback.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !fallback.text.isEmpty {
                        CodeBlock(
                            text: fallback.text,
                            language: "diff",
                            maxLines: 14,
                            tint: Design.accent)
                            .frame(maxHeight: 270)
                    }
                    if fallback.truncated {
                        Text("Raw diff text is truncated to the review display limit.")
                            .font(.caption)
                            .foregroundStyle(Design.warning)
                    }
                }
            }
            ForEach(Array(projection.omissions.enumerated()), id: \.offset) { _, omission in
                Label(omission, systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(Design.warning)
            }
        }
    }

    private func projectedSection(
        _ section: RepositoryReviewDiffSection,
        identity: RepositoryReviewFeedbackIdentity
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: section.kind == .binary ? "doc.zipper" : "doc.text")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(section.kind == .binary || section.kind == .submodule
                                ? Design.warning : Design.accent)
                        Text(section.path.map(sanitized) ?? "Path unavailable")
                            .font(Design.mono(10.5, weight: .semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 5) {
                        Chip(
                            text: section.diffKind.capitalized,
                            symbol: diffSymbol(section.diffKind),
                            tint: diffTint(section.diffKind))
                        Text(section.kind.rawValue)
                        if let originalPath = section.originalPath {
                            Text("from \(sanitized(originalPath))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let anchor = section.fileAnchor(identity: identity) {
                    Button {
                        requestAnchor(anchor)
                    } label: {
                        Label("Comment", systemImage: "text.badge.plus")
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Comment on file \(sanitized(anchor.path))")
                        .help("Attach feedback to this file")
                }
            }

            if section.kind == .binary || section.kind == .submodule {
                Text(section.fallbackReason ?? "The file body is unavailable for review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if section.hunks.isEmpty {
                if !section.rawSection.isEmpty {
                    CodeBlock(
                        text: section.rawSection,
                        language: "diff",
                        maxLines: 14,
                        tint: Design.accent)
                        .frame(maxHeight: 270)
                }
                if section.rawSectionTruncated {
                    Text("Raw file text is truncated to the review display limit.")
                        .font(.caption)
                        .foregroundStyle(Design.warning)
                }
            } else {
                let anchors = section.hunkAnchors(identity: identity)
                ForEach(Array(section.hunks.enumerated()), id: \.offset) { index, hunk in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(sanitized(hunk.header))
                                .font(Design.mono(9.5, weight: .semibold))
                                .textSelection(.enabled)
                            Spacer(minLength: 6)
                            if anchors.indices.contains(index) {
                                Button {
                                    requestAnchor(anchors[index])
                                } label: {
                                    Label("Comment", systemImage: "text.badge.plus")
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel(
                                        "Comment on hunk \(sanitized(hunk.header)) in "
                                            + "\(sanitized(section.path ?? "file"))")
                                    .help("Attach feedback to this hunk")
                            }
                        }
                        if !hunk.context.isEmpty {
                            ReviewHunkCodeBlock(hunk: hunk)
                        }
                        if hunk.contextTruncated {
                            Text("Displayed hunk context was bounded.")
                                .font(.caption)
                                .foregroundStyle(Design.warning)
                        }
                    }
                    .padding(8)
                    .background(Design.accent.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            Divider().opacity(0.35)
        }
    }

    private func rawDiffs(_ review: ObservedRepositoryReview) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(review.diffs.enumerated()), id: \.offset) { _, diff in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Chip(
                            text: diff.kind.capitalized,
                            symbol: diffSymbol(diff.kind),
                            tint: diffTint(diff.kind))
                        Text("\(diff.byteCount) bytes")
                            .font(Design.numeric(9.5))
                            .foregroundStyle(.tertiary)
                        if diff.truncated { Chip(text: "bounded", tint: Design.warning) }
                    }
                    if let text = diff.text, !text.isEmpty {
                        CodeBlock(text: text, language: "diff", maxLines: 14, tint: Design.accent)
                            .frame(maxHeight: 270)
                    } else {
                        Text("Diff text was excluded from this bounded observation.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func omissionsCard(_ review: ObservedRepositoryReview) -> some View {
        Card("Omissions and exclusions", symbol: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 7) {
                gapRow(
                    review.coverage.untrackedNamesOnly,
                    title: "Untracked content gap",
                    detail: "Names and status are shown; file bodies were not read.")
                gapRow(
                    review.coverage.ignoredNamesOnly,
                    title: "Ignored content gap",
                    detail: "Names and status are shown; ignored bodies were not read.")
                gapRow(
                    review.coverage.binaryBodiesExcluded,
                    title: "Binary content gap",
                    detail: "Binary bodies are excluded; status remains visible.")
                gapRow(
                    review.coverage.submoduleBodiesExcluded,
                    title: "Submodule content gap",
                    detail: "Submodule contents are outside this worktree observation.")
                if !review.omissions.isEmpty {
                    Divider().opacity(0.5)
                    Text("Recorded omissions")
                        .font(Design.sectionTitle)
                        .foregroundStyle(.secondary)
                    ForEach(Array(review.omissions.enumerated()), id: \.offset) { _, omission in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(Design.warning)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sanitized(omission.kind))
                                    .font(.system(size: 10.5, weight: .semibold))
                                if let path = omission.path {
                                    Text(sanitized(path))
                                        .font(Design.mono(9.5))
                                        .foregroundStyle(.secondary)
                                }
                                Text(sanitized(omission.detail))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !review.exclusions.isEmpty {
                    Divider().opacity(0.5)
                    Text("Excluded by observation contract")
                        .font(Design.sectionTitle)
                        .foregroundStyle(.secondary)
                    ForEach(Array(review.exclusions.enumerated()), id: \.offset) { _, exclusion in
                        Label(sanitized(exclusion), systemImage: "minus")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var feedbackCard: some View {
        Card("Request a revision", symbol: "text.bubble") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Draft feedback")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer(minLength: 6)
                    Chip(text: "not sent", symbol: "paperplane", tint: .secondary)
                }
                Text("Add bounded feedback to the existing composer. Review delivery there before sending.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let selectedAnchor {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Label(anchorLabel(selectedAnchor), systemImage: "scope")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Clear location") { clearAnchor() }
                            .buttonStyle(.plain)
                            .font(.caption)
                    }
                    .foregroundStyle(selectedAnchorIsCurrent ? Design.accent : Design.warning)
                    if !selectedAnchorIsCurrent {
                        Text("This location is unavailable until its exact saved review is loaded and verified. The draft has not been retargeted.")
                            .font(.caption)
                            .foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("General review feedback", systemImage: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $feedback)
                    .font(.system(size: 11.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72, maxHeight: 120)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1))
                    .accessibilityLabel("Revision feedback")
                    .focused($feedbackFocused)
                VStack(alignment: .leading, spacing: 6) {
                    Button("Place in composer") { placeFeedbackInComposer() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canPlaceFeedback)
                    if placedInComposer {
                        Label(
                            "Placed \(placedFeedbackCount) feedback characters; review delivery in the composer",
                            systemImage: "checkmark")
                            .font(.system(size: 10))
                            .foregroundStyle(Design.success)
                    }
                    Text(feedbackCapacityLabel)
                        .font(Design.numeric(9.5))
                        .foregroundStyle(
                            feedback.utf8.count > feedbackEntryByteCapacity
                                ? Design.warning : Color.secondary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .id("repository-review-feedback")
    }

    private func gapRow(_ present: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: present ? "info.circle" : "checkmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(present ? Design.warning : Design.success)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10.5, weight: .semibold))
                Text(present ? detail : "None recorded")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadReview() {
        guard let run else {
            if !fixtureRetryEnabled { state = .failed(.unavailable) }
            return
        }
        guard selectedIsLoadable, let descriptor = selectedDescriptor else {
            state = .failed(.unavailable)
            return
        }
        state = .loading
        let identity = UUID()
        loadIdentity = identity
        Task { @MainActor in
            let result = await run.loadServiceRepositoryReview(expectedDescriptor: descriptor)
            guard loadIdentity == identity, selectedDescriptor == descriptor else { return }
            loadIdentity = nil
            switch result {
            case .success(let review):
                let projection = try? RepositoryReviewDiffProjection.prepare(
                    review: review, descriptor: descriptor)
                state = .loaded(review, projection)
            case .failure(let error): state = .failed(error)
            }
        }
    }

    private func selectReview(_ descriptor: WorkServiceArtifactDescriptor) {
        guard descriptor != selectedDescriptor else { return }
        persistCurrentDraft()
        loadIdentity = nil
        selectedDescriptor = descriptor
        let draft = drafts[descriptor] ?? ReviewDraft()
        feedback = draft.feedback
        selectedAnchor = draft.anchor
        pendingAnchor = nil
        state = .ready
        placedInComposer = false
        placedFeedbackCount = 0
    }

    private func historyDidChange() {
        // A later publication does not retarget an older selection. A removed or changed exact
        // descriptor invalidates its body; retry never silently substitutes another review.
        guard !selectedIsAvailable else { return }
        loadIdentity = nil
        state = .failed(.unavailable)
    }

    private func placeFeedbackInComposer() {
        guard let run, let composedFeedback else { return }
        let separator = run.draft.isEmpty ? "" : "\n\n"
        let candidate = run.draft + separator + composedFeedback
        run.setDraft(candidate)
        guard run.draft == candidate else {
            placedInComposer = false
            placedFeedbackCount = 0
            return
        }
        placedFeedbackCount = Self.prefix(
            feedback, fittingUTF8Bytes: feedbackEntryByteCapacity).count
        placedInComposer = true
    }

    private func requestAnchor(_ anchor: RepositoryReviewFeedbackAnchor) {
        guard anchorBelongsToLoadedReview(anchor) else { return }
        if selectedAnchor == anchor {
            focusFeedback()
            return
        }
        if !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingAnchor = anchor
            return
        }
        setAnchor(anchor)
        focusFeedback()
    }

    private func moveFeedbackToPendingAnchor() {
        guard let pendingAnchor, anchorBelongsToLoadedReview(pendingAnchor) else {
            self.pendingAnchor = nil
            return
        }
        self.pendingAnchor = nil
        setAnchor(pendingAnchor)
        focusFeedback()
    }

    private func clearAnchor() {
        selectedAnchor = nil
        persistCurrentDraft()
        placedInComposer = false
        placedFeedbackCount = 0
    }

    private func setAnchor(_ anchor: RepositoryReviewFeedbackAnchor) {
        selectedAnchor = anchor
        persistCurrentDraft()
        placedInComposer = false
        placedFeedbackCount = 0
    }

    private func focusFeedback() {
        feedbackScrollRequest &+= 1
    }

    private func persistCurrentDraft() {
        guard let selectedDescriptor else { return }
        let draft = ReviewDraft(feedback: feedback, anchor: selectedAnchor)
        if draft.feedback.isEmpty && draft.anchor == nil {
            drafts.removeValue(forKey: selectedDescriptor)
        } else {
            drafts[selectedDescriptor] = draft
        }
    }

    private func reviewPickerLabel(
        index: Int,
        descriptor: WorkServiceArtifactDescriptor
    ) -> String {
        let base = index == reviewRows.count - 1
            ? "Latest · Saved review \(index + 1)"
            : "Saved review \(index + 1)"
        let draft = descriptor == selectedDescriptor
            ? ReviewDraft(feedback: feedback, anchor: selectedAnchor)
            : drafts[descriptor]
        let hasDraft = draft.map {
            !$0.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.anchor != nil
        } ?? false
        return hasDraft ? base + " · draft" : base
    }

    private var loadedProjection: RepositoryReviewDiffProjection? {
        guard case .loaded(_, let projection) = state else { return nil }
        return projection
    }

    private var selectedAnchorIsCurrent: Bool {
        guard let selectedAnchor else { return false }
        return anchorBelongsToLoadedReview(selectedAnchor)
    }

    private func anchorBelongsToLoadedReview(_ anchor: RepositoryReviewFeedbackAnchor) -> Bool {
        guard let descriptor = selectedDescriptor,
              let descriptorIdentity = try? RepositoryReviewFeedbackIdentity(descriptor: descriptor),
              descriptorIdentity == anchor.identity,
              loadedProjection?.identity == descriptorIdentity else { return false }
        return true
    }

    private func anchorLabel(_ anchor: RepositoryReviewFeedbackAnchor?) -> String {
        guard let anchor else { return "general review feedback" }
        if let hunk = anchor.hunkHeader {
            return "\(sanitized(anchor.path)) · \(sanitized(hunk))"
        }
        return sanitized(anchor.path)
    }

    private var composerRemainingByteCapacity: Int {
        max(0, Self.maximumComposerBytes - (run?.draft.utf8.count ?? 0))
    }

    private var feedbackByteCapacity: Int {
        let separatorBytes = run?.draft.isEmpty == false ? 2 : 0
        return max(0, composerRemainingByteCapacity - separatorBytes)
    }

    private var compositionMaximumBytes: Int {
        min(Self.maximumFeedbackBytes, feedbackByteCapacity)
    }

    private var feedbackEntryByteCapacity: Int {
        guard let selectedAnchor else { return compositionMaximumBytes }
        guard selectedAnchorIsCurrent else { return 0 }
        let prefixBytes = (selectedAnchor.renderedPrefix + "\n").utf8.count
        return max(0, compositionMaximumBytes - prefixBytes)
    }

    private var feedbackCapacityLabel: String {
        if selectedAnchor != nil && !selectedAnchorIsCurrent {
            return "Load the matching review to place this anchored draft · \(feedback.utf8.count) feedback bytes entered"
        }
        return "\(composerRemainingByteCapacity) composer bytes remaining · "
            + "\(feedbackEntryByteCapacity) feedback bytes available "
            + "(\(feedback.utf8.count) entered)"
    }

    private var composedFeedback: String? {
        guard !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let selectedAnchor {
            guard selectedAnchorIsCurrent else { return nil }
            return try? selectedAnchor.composeFeedback(
                feedback, maximumBytes: compositionMaximumBytes)
        }
        let bounded = Self.prefix(feedback, fittingUTF8Bytes: compositionMaximumBytes)
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : bounded
    }

    private var canPlaceFeedback: Bool {
        run != nil && composedFeedback != nil
    }

    /// Preserve extended-grapheme boundaries while applying the durable UTF-8 budget. Swift's
    /// `String.prefix(_:)` counts characters, which can exceed a byte-oriented service bound for
    /// emoji and other multibyte text.
    private static func prefix(_ value: String, fittingUTF8Bytes maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var usedBytes = 0
        var end = value.startIndex
        for character in value {
            let byteCount = String(character).utf8.count
            guard usedBytes <= maximumBytes - byteCount else { break }
            usedBytes += byteCount
            end = value.index(end, offsetBy: 1)
        }
        return String(value[..<end])
    }

    private func statusLabel(_ status: ObservedRepositoryReviewStatus) -> String {
        switch status {
        case .clean: "clean"
        case .changes: "changes"
        case .unstableConflict: "unstable"
        case .notRepository: "not a repository"
        case .timedOut: "timed out"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .bounded: "bounded"
        }
    }

    private func statusTint(_ status: ObservedRepositoryReviewStatus) -> Color {
        switch status {
        case .clean: Design.success
        case .changes: Design.accent
        case .unstableConflict, .timedOut, .cancelled, .failed, .bounded: Design.warning
        case .notRepository: .secondary
        }
    }

    private func statusPair(_ file: ObservedRepositoryFile) -> String {
        let index = file.indexStatus.isEmpty ? "·" : file.indexStatus
        let workTree = file.workTreeStatus.isEmpty ? "·" : file.workTreeStatus
        return sanitized(index + workTree)
    }

    /// Control and line-separator characters are rendered as visible escapes while the original
    /// path remains unchanged in the decoded review and in copyable text selection.
    private func sanitized(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x09: return "\\t"
            case 0x0A: return "\\n"
            case 0x0D: return "\\r"
            case 0x20...0x7E: return String(scalar)
            case 0x7F: return "\\u{7f}"
            case ..<0x20: return String(format: "\\u{%02x}", scalar.value)
            default: return String(scalar)
            }
        }.joined()
    }
}
