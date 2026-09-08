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
        case loaded(ObservedRepositoryReview)
        case failed(RepositoryReviewLoadError)
    }

    private let run: LiveRun?
    @State private var selectedDescriptor: WorkServiceArtifactDescriptor?
    private let fixtureRetryEnabled: Bool
    @State private var state: LoadState
    @State private var feedback = ""
    @State private var placedInComposer = false
    @State private var placedFeedbackCount = 0
    @State private var loadIdentity: UUID?
    @State private var showReviewLimits = false
    @Environment(\.dismiss) private var dismiss

    init(run: LiveRun) {
        self.run = run
        _selectedDescriptor = State(initialValue: run.serviceReviewDescriptor)
        self.fixtureRetryEnabled = false
        _state = State(initialValue: .ready)
    }

    /// Deterministic fixture entry point. Production views never use a preloaded review; this
    /// lets the snapshot harness render the same sheet content without a Work Host.
    init(fixtureReview: ObservedRepositoryReview, fixtureDraft: String? = nil) {
        self.run = fixtureDraft.map {
            LiveRun.productionRunPaneVisualFixture(
                items: [], pendingInputs: [], deliveryAttention: [], actions: [], draft: $0)
        }
        _selectedDescriptor = State(initialValue: nil)
        self.fixtureRetryEnabled = false
        _state = State(initialValue: .loaded(fixtureReview))
    }

    /// Deterministic stale-state entry point for the snapshot harness. Production retry always
    /// reads the current LiveRun descriptor; this route only exercises the safe failure copy.
    init(fixtureError error: RepositoryReviewLoadError, allowsRetry: Bool = false) {
        self.run = nil
        _selectedDescriptor = State(initialValue: nil)
        self.fixtureRetryEnabled = allowsRetry
        _state = State(initialValue: .failed(error))
    }

    private var currentDescriptor: WorkServiceArtifactDescriptor? {
        run?.serviceReviewDescriptor
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    boundaryNotice
                    switch state {
                    case .ready:
                        loadPrompt
                    case .loading:
                        loadingView
                    case .loaded(let review):
                        reviewBody(review)
                    case .failed(let error):
                        failureView(error)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository review")
        .onChange(of: currentDescriptor) { _, descriptor in
            descriptorDidChange(to: descriptor)
        }
        .onDisappear { loadIdentity = nil }
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
            Label(
                "Working-tree changes, not just the agent's edits",
                systemImage: "eye")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Design.accent)
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
        Card("Saved changes", symbol: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    selectedDescriptor == nil
                        ? "A matching review artifact is no longer available."
                        : "Open the recorded file changes and diffs, then prepare feedback for the agent. Aviary checks that the saved review still matches this chat."
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
                Button("Show file changes") {
                    loadReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(run == nil || selectedDescriptor == nil)
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
                                || (run != nil && currentDescriptor == nil))
                    Chip(text: "no content shown", tint: detail.tint)
                }
            }
        }
    }

    @ViewBuilder
    private func reviewBody(_ review: ObservedRepositoryReview) -> some View {
        statusCard(review)
        filesCard(review)
        diffsCard(review)
        omissionsCard(review)
        feedbackCard
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
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(review.files, id: \.path) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(sanitized(file.path))
                                    .font(Design.mono(10))
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer(minLength: 4)
                                Text(statusPair(file))
                                    .font(Design.mono(9.5, weight: .semibold))
                                    .foregroundStyle(Design.accent)
                            }
                            HStack(spacing: 5) {
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
                        if file.path != review.files.last?.path { Divider().opacity(0.35) }
                    }
                }
            }
        }
    }

    private func diffsCard(_ review: ObservedRepositoryReview) -> some View {
        Card("Unified diffs", symbol: "arrow.left.arrow.right") {
            if review.diffs.isEmpty {
                Text("No tracked diff body was retained.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(review.diffs.enumerated()), id: \.offset) { _, diff in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Text(diff.kind.capitalized)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("\(diff.byteCount) bytes")
                                    .font(Design.numeric(9.5))
                                    .foregroundStyle(.tertiary)
                                if diff.truncated {
                                    Chip(text: "bounded", tint: Design.warning)
                                }
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
                Text("Add bounded feedback to the existing composer. Nothing is sent from this sheet.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                HStack(spacing: 8) {
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
                    Spacer()
                    Text(
                        "\(composerRemainingByteCapacity) composer bytes remaining · "
                            + "accepts up to \(min(Self.maximumFeedbackBytes, feedbackByteCapacity)) "
                            + "feedback bytes (\(feedback.utf8.count)/2,000 entered)")
                        .font(Design.numeric(9.5))
                        .foregroundStyle(
                            feedback.utf8.count > Self.maximumFeedbackBytes
                                ? Design.warning : Color.secondary.opacity(0.7))
                }
            }
        }
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
        // Retry adopts the descriptor currently mirrored by LiveRun. It never reuses the
        // descriptor that was selected when this sheet was first presented.
        selectedDescriptor = run.serviceReviewDescriptor
        guard let descriptor = selectedDescriptor else {
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
            case .success(let review): state = .loaded(review)
            case .failure(let error): state = .failed(error)
            }
        }
    }

    private func descriptorDidChange(to descriptor: WorkServiceArtifactDescriptor?) {
        loadIdentity = nil
        let wasShowingBody: Bool
        switch state {
        case .loaded, .loading: wasShowingBody = true
        case .ready, .failed: wasShowingBody = false
        }
        selectedDescriptor = descriptor
        guard wasShowingBody else { return }
        // A descriptor identity change invalidates any body already on screen. Keep the
        // failure copy deliberately coarse; a later retry will adopt the new descriptor.
        state = .failed(.unavailable)
    }

    private func placeFeedbackInComposer() {
        guard let run, canPlaceFeedback else { return }
        let boundedFeedback = Self.prefix(
            feedback,
            fittingUTF8Bytes: min(Self.maximumFeedbackBytes, feedbackByteCapacity))
        guard !boundedFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let separator = run.draft.isEmpty ? "" : "\n\n"
        let candidate = run.draft + separator + boundedFeedback
        run.setDraft(candidate)
        guard run.draft == candidate else {
            placedInComposer = false
            placedFeedbackCount = 0
            return
        }
        placedFeedbackCount = boundedFeedback.count
        placedInComposer = true
    }

    private var composerRemainingByteCapacity: Int {
        max(0, Self.maximumComposerBytes - (run?.draft.utf8.count ?? 0))
    }

    private var feedbackByteCapacity: Int {
        let separatorBytes = run?.draft.isEmpty == false ? 2 : 0
        return max(0, composerRemainingByteCapacity - separatorBytes)
    }

    private var canPlaceFeedback: Bool {
        run != nil
            && !Self.prefix(
                feedback,
                fittingUTF8Bytes: min(Self.maximumFeedbackBytes, feedbackByteCapacity))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
