import SwiftUI
import AppKit
import AviaryCore

/// Browse and read saved sessions.
///
/// A three-pane reader: list, transcript, inspector. The list is the whole catalog — the
/// harness's own session picker shows the first message, which for an agent run is
/// almost never the useful identifier, so rows carry project, branch, model, tool volume,
/// sub-agent count, and spend instead.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: SortOrder = .recent
    @State private var filter: Filter = .all
    @State private var selectedItem: TranscriptItem?
    @State private var confirmTrashSelection = false

    enum SortOrder: String, CaseIterable {
        case recent = "Recent"
        case tokens = "Tokens"
        case cost = "Cost"
        case length = "Turns"
        case project = "Project"
    }

    enum Filter: String, CaseIterable {
        case all = "All"
        case archived = "Archived"
        case live = "Live"
        case substantial = "Substantial"
        case withSubagents = "Fan-outs"
        case errors = "With errors"
    }

    /// Two resizable panes in a split view, plus a fixed-width inspector column.
    ///
    /// Not `.inspector`: that adds a column *outside* the `HSplitView`, so the two layouts
    /// negotiate width independently and nothing enforces that their minimums fit together.
    /// When they don't — a 1120pt window leaves ~900pt for parts demanding 980 — the split
    /// view overflows and clips on the left while the inspector column draws a band of
    /// uninitialized backing store that flickers every frame.
    ///
    /// Not a third `HSplitView` pane either: a conditional child confuses NSSplitView's
    /// arrangement badly enough that the whole split view stops filling its container. A
    /// plain trailing column costs the inspector its drag handle and is correct at every
    /// width, which is the better trade.
    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                listPane
                    .frame(minWidth: 240, idealWidth: 350, maxWidth: 560)
                transcriptPane
                    .frame(minWidth: 320)
            }
            if model.showInspector {
                Divider()
                SessionInspector(selectedItem: $selectedItem)
                    .frame(width: 320)
                    // Painted here rather than inside the inspector: a ScrollView's
                    // background covers its content, not the column, so a short inspector
                    // left the rest of the strip as undefined pixels.
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .confirmationDialog(
            "Move \(model.selectedSessionIDs.count) session\(model.selectedSessionIDs.count == 1 ? "" : "s") to the Trash?",
            isPresented: $confirmTrashSelection)
        {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashSelectedSessions() }
            }
        } message: {
            Text("Aviary will move each selected transcript and its artifacts to macOS Trash. "
                + "Any partial failure is reported; nothing is permanently deleted.")
        }
    }

    // MARK: List

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Search titles, prompts, models…", text: Binding(
                    get: { model.sessionSearch },
                    set: { model.sessionSearch = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !model.sessionSearch.isEmpty {
                    Button {
                        model.sessionSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            HStack(spacing: 6) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 108)

                Picker("", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 92)

                Spacer()
                Text("\(rows.count)")
                    .font(Design.numeric(10))
                    .foregroundStyle(.tertiary)
                    .help("Shift-click selects a range. Command-click adds or removes a session.")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.bar)

            Divider()

            if model.selectedSessionIDs.count > 1 {
                selectionActions
                Divider()
            }

            if rows.isEmpty {
                EmptyStateView(
                    symbol: model.isScanning ? "hourglass" : "tray",
                    title: model.isScanning ? "Scanning sessions…" : "Nothing matches",
                    message: model.isScanning
                        ? "Reading \(model.scanProgress.total) transcript files."
                        : "Try a different filter, or clear the search.")
            } else {
                // A Set binding is the native macOS multi-selection contract: Shift selects
                // a range and Command adds/removes rows. Keep the focused transcript separate
                // so selecting a batch never starts several expensive transcript reads.
                    List(selection: Binding(
                    get: { model.selectedSessionIDs },
                    set: { ids in
                        selectedItem = nil
                        model.setSelectedSessions(ids)
                    }))
                {
                    ForEach(rows) { s in
                        SessionRow(
                            session: s,
                            canonical: model.canonicalCatalogProjections[s.id])
                            .tag(s.id)
                            .contextMenu { contextMenu(for: s) }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .background(.background.secondary)
    }

    private var selectionActions: some View {
        let selected = model.selectedSessions
        let containsLive = selected.contains {
            $0.isCanonicalOnly || $0.isLive || model.hasLiveWork(forSession: $0.id)
        }
        return HStack(spacing: 6) {
            Label("\(selected.count) selected", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Design.accent)
            Spacer(minLength: 0)
            Menu {
                Button("Copy session IDs") { copySessionIDs(selected) }
                Button("Reveal transcripts in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        selected.compactMap(\.fileURL))
                }
                .disabled(selected.allSatisfy(\.isCanonicalOnly))
                Divider()
                let allArchived = selected.allSatisfy(\.isArchived)
                Button(allArchived ? "Restore from Archive" : "Archive selected") {
                    Task { await model.setSessionsArchived(selected, archived: !allArchived) }
                }
                .disabled(model.isArchivingSessions || selected.contains(where: \.isCanonicalOnly))
                Button("Move \(selected.count) to Trash…", role: .destructive) {
                    confirmTrashSelection = true
                }
                .disabled(containsLive || model.isTrashingSessions)
                if containsLive {
                    Text("Native canonical rows are observe-only; deselect them and any live "
                        + "sessions before moving legacy transcripts to the Trash.")
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Design.accentSoft.opacity(0.45))
    }

    private func copySessionIDs(_ sessions: [SessionSummary]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessions.map(\.id).joined(separator: "\n"), forType: .string)
        model.show("Copied \(sessions.count) session IDs")
    }

    private var rows: [SessionSummary] {
        var out = model.filteredSessions
        switch filter {
        case .all: out = out.filter { !$0.isArchived }
        case .archived: out = out.filter(\.isArchived)
        case .live:
            // A canonical row is live only when its aligned Work projection proves that fact.
            // Invalid/missing canonical state remains unknown and must not be treated as idle
            // (or silently promoted into this filter) from compatibility sentinels.
            out = out.filter { session in
                guard let canonical = model.canonicalCatalogProjections[session.id] else {
                    return session.isLive
                }
                guard canonical.sessionStructuralIntegrityValid,
                      canonical.sessionSemanticProjectionValid
                else { return false }
                return canonical.work.contains {
                    $0.canProjectExecution && $0.lifecycle == .active
                }
            }
        case .substantial: out = out.filter(\.isSubstantial)
        case .withSubagents: out = out.filter { $0.childCount > 0 }
        case .errors: out = out.filter { $0.counts.toolErrors > 0 }
        }
        switch sortOrder {
        case .recent: out.sort {
            if $0.isCanonicalOnly != $1.isCanonicalOnly { return !$0.isCanonicalOnly }
            return $0.updatedAt > $1.updatedAt
        }
        case .tokens: out.sort {
            if $0.isCanonicalOnly != $1.isCanonicalOnly { return !$0.isCanonicalOnly }
            return $0.usage.totalTokens > $1.usage.totalTokens
        }
        case .cost: out.sort {
            if $0.isCanonicalOnly != $1.isCanonicalOnly { return !$0.isCanonicalOnly }
            return $0.usage.cost.total > $1.usage.cost.total
        }
        case .length: out.sort {
            if $0.isCanonicalOnly != $1.isCanonicalOnly { return !$0.isCanonicalOnly }
            return $0.counts.assistant > $1.counts.assistant
        }
        case .project: out.sort {
            if $0.isCanonicalOnly != $1.isCanonicalOnly { return !$0.isCanonicalOnly }
            return ($0.projectName, $1.updatedAt) < ($1.projectName, $0.updatedAt) }
        }
        return out
    }

    @ViewBuilder
    private func contextMenu(for s: SessionSummary) -> some View {
        Button("Reveal transcript in Finder") {
            if let url = s.fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .disabled(s.isCanonicalOnly)
        Button("Open working directory") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
        }
        .disabled(s.isCanonicalOnly || s.cwd.isEmpty)
        Button("Copy session id") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.id, forType: .string)
        }
        Button("Copy resume command") {
            // Matches the selected engine, so pasting it continues the session the same way
            // the Continue button would.
            let command = model.preferInHouseEngine
                ? "Aviary --agent \"<prompt>\" --cwd \(s.cwd) --resume \(s.id)"
                : "prime-agent --cwd \(s.cwd) -r \(s.id)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        .disabled(s.isCanonicalOnly)
        Divider()
        Button("Continue this session in a new run") {
            model.continueSession(s)
        }
        .disabled(s.isCanonicalOnly || s.isLive || model.hasLiveWork(forSession: s.id))
        Button(s.isArchived ? "Restore from Archive" : "Archive session") {
            Task { await model.setSessionsArchived([s], archived: !s.isArchived) }
        }
        .disabled(model.isArchivingSessions || s.isCanonicalOnly)
        Divider()
        let targets = model.selectedSessionIDs.contains(s.id) ? model.selectedSessions : [s]
        Button(targets.count == 1 ? "Move to Trash…" : "Move \(targets.count) selected to Trash…",
               role: .destructive)
        {
            if !model.selectedSessionIDs.contains(s.id) {
                selectedItem = nil
                model.setSelectedSessions([s.id])
            }
            confirmTrashSelection = true
        }
        .disabled(
            targets.contains {
                $0.isCanonicalOnly || $0.isLive || model.hasLiveWork(forSession: $0.id)
            }
                || model.isTrashingSessions)
    }

    // MARK: Transcript

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            if let t = model.transcript {
                TranscriptHeader(transcript: t)
                Divider()
                TranscriptView(
                    items: t.items,
                    searchQuery: model.transcriptSearch,
                    hideThinking: model.hideThinking,
                    isStreaming: model.selectedSession?.isBusy ?? false,
                    autoScroll: model.selectedSession?.isBusy ?? false,
                    onSelect: { selectedItem = $0 })
            } else if model.isLoadingTranscript {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading transcript…").font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let selected = model.selectedSession, selected.isCanonicalOnly {
                EmptyStateView(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "Canonical session selected",
                    message: "This row is backed by an authority-qualified projection. Its "
                        + "legacy transcript and runtime context are not available in this GUI.")
            } else {
                EmptyStateView(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "Pick a session",
                    message: "Aviary reads the transcript files directly, so this works even "
                        + "when no Work is currently running.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { transcriptSearchBar }
    }

    @ViewBuilder
    private var transcriptSearchBar: some View {
        if model.transcript != nil {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 7) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("Find in transcript", text: Binding(
                        get: { model.transcriptSearch },
                        set: { model.transcriptSearch = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !model.transcriptSearch.isEmpty {
                        Button {
                            model.transcriptSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                    Divider().frame(height: 14)
                    Toggle(isOn: Binding(
                        get: { model.hideThinking },
                        set: { model.hideThinking = $0 }))
                    {
                        Label("Hide thinking", systemImage: "brain")
                            .font(.system(size: 10.5))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }
}

// MARK: - Transcript header

struct TranscriptHeader: View {
    @Environment(AppModel.self) private var model
    var transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(transcript.sessionName ?? model.selectedSession?.title ?? "Session")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let state = transcript.sessionState {
                    Chip(text: state,
                         tint: state == "active" ? Design.success : .secondary)
                }
                if let outcome = transcript.outcome {
                    Chip(
                        text: outcome.state.rawValue,
                        symbol: outcome.state == .failed
                            ? "exclamationmark.triangle.fill" : "stop.circle.fill",
                        tint: outcome.state == .failed ? Design.danger : Design.warning)
                }
                if model.selectedSession?.isBusy == true {
                    HStack(spacing: 4) {
                        PulseDot()
                        Text("live").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Design.success)
                    }
                }
                Spacer()
                if transcript.unparsedLines > 0 {
                    Chip(text: "\(transcript.unparsedLines) unreadable lines",
                         symbol: "exclamationmark.triangle", tint: Design.warning)
                        .help("Aviary could not parse these entries — likely a session format "
                            + "change. Everything else rendered normally.")
                }
            }

            if let status = transcript.status, !status.summary.isEmpty {
                Text(status.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let outcome = transcript.outcome, let detail = outcome.detail, !detail.isEmpty {
                NoticeBanner(
                    level: outcome.state == .failed ? .danger : .warning,
                    title: outcome.state == .failed ? "Run failed" : "Run cancelled",
                    message: detail)
            }

            HStack(spacing: 5) {
                if let m = transcript.lastModel {
                    Chip(text: [transcript.lastProvider, m].compactMap { $0 }.joined(separator: "/"),
                         symbol: "cpu", tint: Design.assistant)
                }
                Chip(text: "\(transcript.counts.user)→\(transcript.counts.assistant)",
                     symbol: "arrow.left.arrow.right", tint: .secondary)
                    .help("\(transcript.counts.user) prompts, \(transcript.counts.assistant) model turns")
                if transcript.counts.toolCalls > 0 {
                    Chip(text: "\(transcript.counts.toolCalls)", symbol: "terminal",
                         tint: Design.tool)
                        .help("tool calls")
                }
                if transcript.counts.toolErrors > 0 {
                    Chip(text: "\(transcript.counts.toolErrors)",
                         symbol: "exclamationmark.triangle", tint: Design.danger)
                        .help("tool errors")
                }
                if transcript.counts.agentMessages > 0 {
                    Chip(text: "\(transcript.counts.agentMessages)",
                         symbol: "arrow.left.arrow.right.circle", tint: Design.agentMessage)
                        .help("agent-to-agent messages")
                }
                Chip(text: Fmt.tokens(transcript.usage.totalTokens), symbol: "number",
                     tint: .secondary)
                if transcript.usage.cost.total > 0 {
                    Chip(text: Fmt.cost(transcript.usage.cost.total), tint: Design.accent)
                }
                if let d = transcript.duration {
                    Chip(text: Fmt.duration(d), symbol: "clock", tint: .secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, Design.gutter)
        .padding(.vertical, 10)
        .background(.background.secondary)
    }
}

// MARK: - Inspector

struct SessionInspector: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedItem: TranscriptItem?
    @State private var showBreakdown = false
    @State private var showRaw = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let item = selectedItem {
                    itemCard(item)
                }
                if let s = model.selectedSession {
                    if s.isCanonicalOnly,
                       let canonical = model.canonicalCatalogProjections[s.id] {
                        canonicalSessionCard(canonical)
                    } else {
                        sessionCard(s)
                        usageCard(s)
                    }
                }
                if let t = model.transcript {
                    if !t.modelChanges.isEmpty { modelChangesCard(t) }
                }
                if model.selectedSession?.isCanonicalOnly != true {
                    wireCard
                }
                if let kernel = model.kernelState {
                    kernelCard(kernel)
                }
                subagentsCard
            }
            .padding(12)
        }
    }

    // MARK: What was sent

    /// The recorded provider payload for this session, and — when an assistant turn is
    /// selected — for that specific turn.
    ///
    /// A session's requests and its assistant messages are one-to-one and in order, so the
    /// nth recorded request is what produced the nth model turn. Sub-agents don't disturb
    /// this: they run in their own sessions with their own cache keys, so their payloads are
    /// attributed to them and not to the parent.
    private var wireRequests: [WireRecord] {
        model.selectedSessionWire.filter { $0.kind == .request }
    }

    /// The request that produced the selected assistant message, if one is selected.
    private var requestForSelection: WireRecord? {
        guard let selected = selectedItem, selected.kind == .assistant,
              let transcript = model.transcript
        else { return nil }
        let assistants = transcript.items.filter { $0.kind == .assistant }
        guard let turn = assistants.firstIndex(where: { $0.id == selected.id }),
              wireRequests.indices.contains(turn)
        else { return nil }
        return wireRequests[turn]
    }

    private var shownRequest: WireRecord? {
        requestForSelection ?? wireRequests.last
    }

    @ViewBuilder
    private var wireCard: some View {
        if let request = shownRequest, let payload = request.payload {
            let analysis = WireLog.analyse(payload: payload)
            Card("What was sent", symbol: "arrow.up.doc",
                 accessory: AnyView(
                    HStack(spacing: 8) {
                        Button("Breakdown") { showBreakdown = true }
                            .buttonStyle(.link).font(.system(size: 10))
                        Button("Raw") { showRaw = true }
                            .buttonStyle(.link).font(.system(size: 10))
                    }))
            {
                VStack(alignment: .leading, spacing: 6) {
                    if requestForSelection != nil {
                        Text("For the selected turn — request #\(request.seq).")
                            .font(.system(size: 10)).foregroundStyle(Design.accent)
                    } else if wireRequests.count > 1 {
                        Text("Latest of \(wireRequests.count) recorded requests. Select an "
                            + "assistant turn to see the one that produced it.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DetailRow(
                        label: "Payload",
                        value: "\(Fmt.bytes(analysis.totalCharacters)) · ≈\(Fmt.tokens(analysis.estimatedTokens)) tok")
                    if let billed = billedInput(for: request) {
                        DetailRow(label: "Billed input", value: Fmt.tokens(billed), mono: true)
                    }
                    Divider().opacity(0.5)
                    ForEach(analysis.segments.prefix(4)) { seg in
                        HStack(spacing: 6) {
                            Text(seg.label)
                                .font(.system(size: 10.5))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(String(format: "%.0f%%", 100 * seg.share(of: analysis.totalCharacters)))
                                .font(Design.numeric(10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .sheet(isPresented: $showBreakdown) {
                VStack(spacing: 0) {
                    HStack {
                        Text("What was sent to the model")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Done") { showBreakdown = false }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(12)
                    Divider()
                    ContextBreakdownView(
                        analysis: analysis,
                        actualInputTokens: billedInput(for: request),
                        recordedAt: request.at)
                }
                .frame(width: 820, height: 720)
            }
            .sheet(isPresented: $showRaw) {
                RawPayloadSheet(records: model.selectedSessionWire)
            }
        } else if let session = model.selectedSession, !session.isCanonicalOnly {
            Card("What was sent", symbol: "arrow.up.doc") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("No provider payloads were recorded for this session, so its input "
                        + "tokens can't be broken down. The transcript holds messages; the "
                        + "system prompt, context files, skill catalogue and tool schemas "
                        + "are assembled per request and stored nowhere.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.continueWithRecording(session)
                    } label: {
                        Label("Continue with recording", systemImage: "record.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled((session.isLive || model.hasLiveWork(forSession: session.id))
                        || (!model.preferInHouseEngine
                            && EngineLocator.wireLogExtension() == nil))
                    Text("Replays this conversation in a new runtime with recording on. The next "
                        + "turn records a newly assembled payload from current instructions, "
                        + "context files, memory, skills, and tools.")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Input tokens the provider charged for the turn this request produced.
    private func billedInput(for request: WireRecord) -> Int? {
        guard let transcript = model.transcript else { return nil }
        let assistants = transcript.items.filter { $0.kind == .assistant }
        guard let turn = wireRequests.firstIndex(where: { $0.seq == request.seq }),
              assistants.indices.contains(turn),
              let input = assistants[turn].usage?.input, input > 0
        else { return nil }
        return input
    }

    private func itemCard(_ item: TranscriptItem) -> some View {
        Card("Selected entry", symbol: item.kind.symbol,
             accessory: AnyView(
                Button {
                    selectedItem = nil
                } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(.tertiary)))
        {
            VStack(alignment: .leading, spacing: 5) {
                DetailRow(label: "Kind", value: item.kind.label)
                DetailRow(label: "Entry id", value: item.id, mono: true)
                DetailRow(label: "Time", value: Fmt.timestamp(item.timestamp), mono: true)
                if let m = item.model { DetailRow(label: "Model", value: m, mono: true) }
                if let u = item.usage, !u.isEmpty {
                    DetailRow(label: "Input", value: Fmt.tokens(u.input), mono: true)
                    DetailRow(label: "Output", value: Fmt.tokens(u.output), mono: true)
                    if u.cacheRead > 0 {
                        DetailRow(label: "Cache read", value: Fmt.tokens(u.cacheRead), mono: true)
                    }
                    if let r = u.reasoning {
                        DetailRow(
                            label: "Reasoning", value: Fmt.tokens(r), mono: true,
                            tint: Design.thinking)
                    }
                    if u.cost.total > 0 {
                        DetailRow(label: "Cost", value: Fmt.cost(u.cost.total), mono: true)
                    }
                }
                if let d = item.toolDuration {
                    DetailRow(label: "Tool time", value: Fmt.duration(d), mono: true)
                }
                if let details = item.toolDetails, details.objectValue?.isEmpty == false {
                    Divider().opacity(0.5)
                    Text("TOOL DETAILS")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    CodeBlock(text: details.prettyPrinted, maxLines: 12, tint: .secondary)
                }
            }
        }
    }

    private func sessionCard(_ s: SessionSummary) -> some View {
        Card("Session", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 5) {
                DetailRow(label: "Id", value: s.id, mono: true)
                DetailRow(label: "Working dir", value: s.cwd, mono: true)
                if let b = s.gitBranch { DetailRow(label: "Branch", value: b, mono: true) }
                DetailRow(label: "Created", value: Fmt.timestamp(s.createdAt))
                DetailRow(label: "Updated", value: Fmt.timestamp(s.updatedAt))
                DetailRow(label: "Transcript", value: Fmt.bytes(s.byteSize))
                DetailRow(label: "Entries", value: "\(s.counts.entries)")
                if s.rlmDepth > 0 {
                    DetailRow(label: "RLM depth", value: "\(s.rlmDepth)",
                              tint: Design.agentMessage)
                }
                if let state = s.status?.taskState {
                    DetailRow(label: "Task state", value: state,
                              tint: s.status?.isAwaitingUser == true ? Design.warning : nil)
                }
                Divider().opacity(0.5)
                HStack(spacing: 10) {
                    Button("Reveal") {
                        if let url = s.fileURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .buttonStyle(.link).font(.system(size: 10.5))
                    .disabled(s.isCanonicalOnly)
                    Button("Continue") {
                        model.continueSession(s)
                    }
                    .buttonStyle(.link).font(.system(size: 10.5))
                    .disabled(s.isCanonicalOnly || s.isLive || model.hasLiveWork(forSession: s.id))
                    Spacer()
                }
            }
        }
    }

    private func canonicalSessionCard(_ c: CanonicalSessionCatalogSummary) -> some View {
        Card("Canonical session", symbol: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 6) {
                DetailRow(label: "Identity", value: c.id, mono: true)
                DetailRow(label: "Lifecycle", value: c.lifecycle.rawValue)
                DetailRow(label: "Attention", value: c.effectiveAttention?.rawValue ?? "unknown")
                DetailRow(label: "Model", value: c.modelIDs.isEmpty
                          ? "unknown" : c.modelIDs.joined(separator: ", "))
                Divider().opacity(0.5)
                Text("Work projection")
                    .font(.system(size: 11, weight: .semibold))
                if c.work.isEmpty {
                    DetailRow(label: "Status", value: c.sessionSemanticProjectionValid
                              ? "no attached Work" : "unknown (legacy semantics)")
                    DetailRow(label: "Liveness", value: c.sessionSemanticProjectionValid
                              ? "not running" : "unknown")
                } else {
                    let exact = c.work.filter(\.canProjectExecution)
                    DetailRow(
                        label: "Liveness",
                        value: exact.isEmpty ? "unknown" : (exact.contains {
                            $0.lifecycle == .active
                        } ? "active" : "not active"))
                    ForEach(c.work) { work in
                        VStack(alignment: .leading, spacing: 2) {
                            DetailRow(label: "Host", value: work.workHost.workHostID, mono: true)
                            DetailRow(label: "Availability",
                                      value: work.canProjectExecution && work.isAvailable
                                          ? "available" : "unknown")
                            DetailRow(label: "Execution",
                                      value: work.canProjectExecution
                                          ? work.execution.rawValue : "unknown")
                        }
                    }
                }
                if !c.unknownDomains.isEmpty {
                    Text("Unknown domains: "
                        + c.unknownDomains.map(\.rawValue).sorted().joined(separator: ", "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !c.corruptionReasons.isEmpty {
                    Text(c.corruptionReasons.joined(separator: "\n"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Design.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func usageCard(_ s: SessionSummary) -> some View {
        Card("Usage", symbol: "number") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    StatTile(label: "tokens", value: Fmt.tokens(s.usage.totalTokens))
                    StatTile(label: "cost", value: Fmt.cost(s.usage.cost.total))
                }
                if let rate = s.usage.cacheHitRate {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Cache hit rate").font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.percent(rate)).font(Design.numeric(10, weight: .semibold))
                        }
                        RatioBar(fraction: rate, tint: Design.tool)
                    }
                }
                if !s.childUsage.isEmpty {
                    Divider().opacity(0.5)
                    Text("Sub-agents added \(Fmt.tokens(s.childUsage.totalTokens)) tokens"
                        + (s.childUsage.cost.total > 0
                            ? " (\(Fmt.cost(s.childUsage.cost.total)))" : ""))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Design.agentMessage)
                }
                if s.usage.totalTokens > 0, s.usage.cost.total == 0 {
                    Text("This route reported no pricing, so cost shows as nothing. Token "
                        + "counts are still real.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func modelChangesCard(_ t: Transcript) -> some View {
        Card("Model switches", symbol: "arrow.triangle.swap") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(t.modelChanges.enumerated()), id: \.offset) { _, change in
                    HStack(spacing: 6) {
                        Text(Fmt.clock(change.date)).font(Design.mono(9.5))
                            .foregroundStyle(.tertiary)
                        Text("\(change.provider)/\(change.model)")
                            .font(Design.mono(10))
                        Spacer()
                    }
                }
            }
        }
    }

    private func kernelCard(_ kernel: KernelState) -> some View {
        Card("IPython kernel", symbol: "cube.fill") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Aviary's agent works through a Python runtime, so this namespace is "
                    + "part of its accessible working state.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                DetailRow(label: "Saved names", value: "\(kernel.savedNames.count)")
                DetailRow(label: "State file", value: Fmt.bytes(kernel.stateFileSize))
                if let at = kernel.savedAt {
                    DetailRow(label: "Saved", value: Fmt.timestamp(at))
                }
                if !kernel.savedNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(kernel.savedNames.joined(separator: "  "))
                            .font(Design.mono(9.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 90)
                }
            }
        }
    }

    @ViewBuilder
    private var subagentsCard: some View {
        if let id = model.selectedSessionID {
            let kids = model.tree.roots(forSession: id)
            if !kids.isEmpty {
                // No link out: Flock is hidden until it describes the in-house world rather
                // than the harness's forest of supervisor-held sessions. The rows below are
                // read from the spawn ledger and stand on their own.
                Card("Sub-agents", symbol: "bird.fill") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(kids) { node in
                            Button {
                                Task { await model.loadChildTranscript(node: node) }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(node.isRunning ? Design.success
                                            : node.isFailed ? Design.danger
                                            : Color.secondary.opacity(0.3))
                                        .frame(width: 6, height: 6)
                                    Text(node.name).font(.system(size: 11)).lineLimit(1)
                                    Spacer()
                                    Text(node.status).font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
