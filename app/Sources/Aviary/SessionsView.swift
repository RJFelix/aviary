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

    enum SortOrder: String, CaseIterable {
        case recent = "Recent"
        case tokens = "Tokens"
        case cost = "Cost"
        case length = "Turns"
        case project = "Project"
    }

    enum Filter: String, CaseIterable {
        case all = "All"
        case live = "Live"
        case substantial = "Substantial"
        case withSubagents = "Fan-outs"
        case errors = "With errors"
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            transcriptPane
                .frame(minWidth: 420)
        }
        .inspector(isPresented: Binding(
            get: { model.showInspector },
            set: { model.showInspector = $0 }))
        {
            SessionInspector(selectedItem: $selectedItem)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.bar)

            Divider()

            if rows.isEmpty {
                EmptyStateView(
                    symbol: model.isScanning ? "hourglass" : "tray",
                    title: model.isScanning ? "Scanning sessions…" : "Nothing matches",
                    message: model.isScanning
                        ? "Reading \(model.scanProgress.total) transcript files."
                        : "Try a different filter, or clear the search.")
            } else {
                List(selection: Binding(
                    get: { model.selectedSessionID },
                    set: { id in
                        guard let id, let s = model.sessions.first(where: { $0.id == id }) else { return }
                        selectedItem = nil
                        model.select(session: s)
                    }))
                {
                    ForEach(rows) { s in
                        SessionRow(session: s)
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

    private var rows: [SessionSummary] {
        var out = model.filteredSessions
        switch filter {
        case .all: break
        case .live: out = out.filter(\.isLive)
        case .substantial: out = out.filter(\.isSubstantial)
        case .withSubagents: out = out.filter { $0.childCount > 0 }
        case .errors: out = out.filter { $0.counts.toolErrors > 0 }
        }
        switch sortOrder {
        case .recent: out.sort { $0.updatedAt > $1.updatedAt }
        case .tokens: out.sort { $0.usage.totalTokens > $1.usage.totalTokens }
        case .cost: out.sort { $0.usage.cost.total > $1.usage.cost.total }
        case .length: out.sort { $0.counts.assistant > $1.counts.assistant }
        case .project: out.sort {
            ($0.projectName, $1.updatedAt) < ($1.projectName, $0.updatedAt) }
        }
        return out
    }

    @ViewBuilder
    private func contextMenu(for s: SessionSummary) -> some View {
        Button("Reveal transcript in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([s.fileURL])
        }
        Button("Open working directory") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
        }
        Button("Copy session id") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.id, forType: .string)
        }
        Button("Copy resume command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("prime-agent --cwd \(s.cwd) -r \(s.id)", forType: .string)
        }
        Divider()
        Button("Continue this session in a new run") {
            model.startRun(
                config: RunConfiguration(
                    cwd: s.cwd.isEmpty ? model.defaultCwd : s.cwd,
                    provider: s.provider, model: s.model, resume: s.id),
                firstPrompt: nil)
        }
        .disabled(s.isLive)
        Divider()
        Button("Move to Trash…", role: .destructive) {
            model.selectedSessionID = s.id
            Task { await model.trashSelectedSession() }
        }
        .disabled(s.isLive)
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
            } else {
                EmptyStateView(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "Pick a session",
                    message: "Aviary reads the transcript files directly, so this works even "
                        + "when the background service is down.")
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
                        .help("Aviary could not parse these entries — likely a harness format "
                            + "change. Everything else rendered normally.")
                }
            }

            if let status = transcript.status, !status.summary.isEmpty {
                Text(status.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let item = selectedItem {
                    itemCard(item)
                }
                if let s = model.selectedSession {
                    sessionCard(s)
                    usageCard(s)
                }
                if let t = model.transcript {
                    if !t.modelChanges.isEmpty { modelChangesCard(t) }
                }
                if let kernel = model.kernelState {
                    kernelCard(kernel)
                }
                subagentsCard
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                        NSWorkspace.shared.activateFileViewerSelecting([s.fileURL])
                    }
                    .buttonStyle(.link).font(.system(size: 10.5))
                    Button("Continue") {
                        model.startRun(
                            config: RunConfiguration(
                                cwd: s.cwd.isEmpty ? model.defaultCwd : s.cwd,
                                provider: s.provider, model: s.model, resume: s.id),
                            firstPrompt: nil)
                    }
                    .buttonStyle(.link).font(.system(size: 10.5))
                    .disabled(s.isLive)
                    Spacer()
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
                Text("The harness's only tool is a Python kernel, so this namespace is the "
                    + "agent's working memory.")
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
                Card("Sub-agents", symbol: "bird.fill",
                     accessory: AnyView(
                        Button("Flock") { model.section = .flock }
                            .buttonStyle(.link).font(.system(size: 10))))
                {
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
