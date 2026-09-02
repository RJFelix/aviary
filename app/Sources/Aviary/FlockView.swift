import SwiftUI
import AppKit
import AviaryCore

/// The Work and child view: what delegated Work exists, which Sessions observe it, and what
/// child lifecycle the exact Work journal proves.
///
/// The harness can recurse — an agent calls `rlm(...)` and gets a child with its own
/// kernel, its own transcript, and its own children. In a terminal that structure is
/// invisible: you see one stream of text and a lot of `agent_message` traffic. This screen
/// is the reason a GUI is worth building for this harness at all.
struct FlockView: View {
    private static let maxDisplayedCanonicalWorks = 128
    static let maxDisplayedChildrenPerWork = 64
    @Environment(AppModel.self) private var model
    @State private var selectedNodeID: String?
    @State private var selectedCanonicalWorkID: String?
    @State private var expanded: Set<String> = []
    @State private var showOnlyRunning = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                summaryBar
                Divider()
                if canonicalWorks.isEmpty && legacyRoots.isEmpty {
                    EmptyStateView(
                        symbol: "bird",
                        title: "No delegated Work yet",
                        message: "Native Work and legacy child records will appear here when "
                            + "they are available.")
                } else {
                    treeList
                }
            }
            .frame(minWidth: 330, idealWidth: 440, maxWidth: 640)

            detailPane
                .frame(minWidth: 380)
        }
    }

    // MARK: Data

    private var canonicalAllWorks: [CanonicalFlockCatalogProjection] {
        model.canonicalFlockInventory
    }

    private var canonicalWorks: [CanonicalFlockCatalogProjection] {
        canonicalAllWorks.filter { !showOnlyRunning || isRunning($0) }
    }

    private var canonicalWorksForDisplay: [CanonicalFlockCatalogProjection] {
        Array(canonicalWorks.prefix(Self.maxDisplayedCanonicalWorks))
    }

    /// Only a proven companion may suppress a legacy AgentTree root. A canonical Session's
    /// local sessionID is not enough: another authority may legitimately use the same value.
    private var legacyCompanionSessionIDs: Set<String> {
        model.nativeCompanionLegacyIDs
    }

    /// Legacy topology is a compatibility view only. A Session that has a canonical Work row
    /// is never filled back in from AgentTree when that Work has no child records.
    private var legacyRootsAll: [(session: SessionSummary?, sessionID: String, nodes: [AgentNode])] {
        let eligibleIDs = Set(CanonicalFlockCatalogProjection.legacyCompatibilityRootIDs(
            Array(model.tree.byParentSession.keys),
            nativeCompanionLegacyIDs: legacyCompanionSessionIDs))
        return model.tree.byParentSession
            .map { key, value in
                (session: model.sessions.first { $0.id == key }, sessionID: key, nodes: value)
            }
            .filter { eligibleIDs.contains($0.sessionID) }
    }

    private var legacyRoots: [(session: SessionSummary?, sessionID: String, nodes: [AgentNode])] {
        legacyRootsAll.filter { entry in
                guard showOnlyRunning else { return true }
                return entry.nodes.contains { $0.flattened.contains(where: \.isRunning) }
            }
            .sorted { a, b in
                let aTime = a.nodes.map(\.updatedAt).max() ?? .distantPast
                let bTime = b.nodes.map(\.updatedAt).max() ?? .distantPast
                return aTime > bTime
            }
    }

    private var legacySelection: Binding<String?> {
        Binding(
            get: { selectedNodeID },
            set: {
                selectedNodeID = $0
                if $0 != nil { selectedCanonicalWorkID = nil }
            })
    }

    private var selectedNode: AgentNode? {
        guard let id = selectedNodeID else { return nil }
        for roots in model.tree.byParentSession.values {
            if let node = roots.flatMap(\.flattened).first(where: {
                LegacyFlockIdentity.rowID(
                    parentSessionID: $0.parentSessionID, childID: $0.id) == id
            }) { return node }
        }
        return nil
    }

    private var selectedCanonicalWork: CanonicalFlockCatalogProjection? {
        guard let id = selectedCanonicalWorkID else { return nil }
        return canonicalWorks.first { $0.id == id }
    }

    private func isRunning(_ work: CanonicalFlockCatalogProjection) -> Bool {
        work.isRunning
    }

    private var summaryBar: some View {
        let canonicalRunning = canonicalAllWorks.filter(isRunning).count
        let legacyChildren = legacyRootsAll.flatMap(\.nodes).flatMap(\.flattened)
        let legacyRunning = legacyChildren.filter(\.isRunning).count
        let attentionCount = CanonicalFlockCatalogProjection.attentionSessionCount(canonicalAllWorks)
        return HStack(spacing: 14) {
            StatTile(
                label: "Work", value: "\(canonicalAllWorks.count)",
                symbol: "circle.hexagongrid.fill", tint: Design.agentMessage)
            StatTile(
                label: "running",
                value: "\(canonicalRunning + legacyRunning)",
                symbol: "bolt.fill",
                tint: canonicalRunning + legacyRunning > 0 ? Design.success : .secondary)
            StatTile(
                label: "children", value: "\(canonicalAllWorks.flatMap(\.children).count)",
                caption: legacyChildren.isEmpty ? "canonical lifecycle"
                    : "\(legacyChildren.count) legacy",
                symbol: "arrow.triangle.branch")
            StatTile(
                label: "attention",
                value: "\(attentionCount)",
                symbol: "exclamationmark.bubble")
            Spacer()
            Toggle("Running only", isOn: $showOnlyRunning)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10.5))
        }
        .padding(.horizontal, Design.gutter)
        .padding(.vertical, 9)
        .background(.background.secondary)
    }

    private var treeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if canonicalWorks.count > canonicalWorksForDisplay.count {
                    Text("Showing first \(canonicalWorksForDisplay.count) of \(canonicalWorks.count) Work rows")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(canonicalWorksForDisplay) { work in
                    CanonicalFlockWorkRow(
                        work: work, selectedID: $selectedCanonicalWorkID,
                        onSelect: { selectedNodeID = nil })
                }

                if !legacyRoots.isEmpty {
                    Text("Legacy compatibility")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, canonicalWorks.isEmpty ? 0 : 5)
                    ForEach(legacyRoots, id: \.sessionID) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
                            selectedCanonicalWorkID = nil
                            model.openTranscript(sessionID: entry.sessionID)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.square.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Design.user)
                                Text(entry.session?.title ?? entry.sessionID)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Chip(text: "\(entry.nodes.flatMap(\.flattened).count)",
                                     symbol: "bird", tint: Design.agentMessage)
                                Spacer()
                                if let s = entry.session {
                                    Text(Fmt.ago(s.updatedAt))
                                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        FanoutTimeline(
                            nodes: entry.nodes.flatMap(\.flattened), selectedID: legacySelection)

                        ForEach(Array(entry.nodes.enumerated()), id: \.offset) { _, node in
                            AgentNodeRow(
                                node: node,
                                depth: 0,
                                selectedID: legacySelection,
                                expanded: $expanded)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.background.secondary))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 1))
                    }
                }
            }
            .padding(Design.gutter)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if let work = selectedCanonicalWork {
            CanonicalFlockDetail(work: work)
        } else if let node = selectedNode {
            AgentNodeDetail(node: node)
        } else {
            EmptyStateView(
                symbol: "sidebar.right",
                title: "Pick Work or a legacy child",
                message: "Canonical Work is authoritative for lifecycle and attention. Legacy "
                    + "child details remain available only where no native projection exists.")
        }
    }
}

private struct CanonicalFlockWorkRow: View {
    let work: CanonicalFlockCatalogProjection
    @Binding var selectedID: String?
    let onSelect: () -> Void

    private var selected: Bool { selectedID == work.id }
    private var running: Bool {
        work.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                onSelect()
                selectedID = work.id
            } label: {
                HStack(spacing: 7) {
                    if running {
                        PulseDot(color: Design.success)
                    } else if !work.isAvailable || !work.childLifecycleAvailable {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(Design.warning)
                    } else {
                        Circle().fill(.tertiary).frame(width: 7, height: 7)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(work.sessions.first?.title ?? "Unattached Work")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(work.id).font(Design.mono(9)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let attention = work.attentionStatus.attention,
                       work.attentionStatus.requirement == .required {
                        Chip(text: attention.rawValue, symbol: "exclamationmark.bubble",
                             tint: Design.warning, filled: true)
                    } else if work.attentionStatus.requirement == .unknown {
                        Chip(text: "attention unknown", symbol: "questionmark.bubble",
                             tint: Design.warning)
                    }
                    Chip(text: work.childLifecycleAvailable ? "\(work.children.count)" : "?",
                         symbol: "bird",
                         tint: Design.agentMessage)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                if let host = work.workHost {
                    Chip(text: host.workHostID, symbol: "server.rack")
                }
                if let lifecycle = work.lifecycle { Chip(text: lifecycle.rawValue) }
                if let execution = work.execution { Chip(text: execution.rawValue) }
                if let model = work.modelID {
                    Text(model).font(Design.mono(9)).foregroundStyle(.tertiary)
                }
                Spacer()
            }

            if work.childLifecycleAvailable {
                if work.children.isEmpty {
                    Text("No child lifecycle records at this Work tip.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(work.children.prefix(FlockView.maxDisplayedChildrenPerWork))) { child in
                        HStack(spacing: 6) {
                            Circle().fill(child.state == "running"
                                          ? AnyShapeStyle(Design.success)
                                          : AnyShapeStyle(.tertiary))
                                .frame(width: 6, height: 6)
                            Text(child.name ?? child.childID).font(.system(size: 11))
                            Spacer()
                            Text(child.state).font(Design.mono(9)).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 12)
                    }
                    if work.children.count > FlockView.maxDisplayedChildrenPerWork {
                        Text("+\(work.children.count - FlockView.maxDisplayedChildrenPerWork) children omitted")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.leading, 12)
                    }
                }
            } else {
                Text(work.unavailableReason ?? "Child lifecycle is unavailable")
                    .font(.system(size: 10)).foregroundStyle(Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(Design.accentSoft)
                      : AnyShapeStyle(.background.secondary)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Design.accent.opacity(0.7))
                              : AnyShapeStyle(.separator.opacity(0.6)), lineWidth: 1))
    }
}

private struct CanonicalFlockDetail: View {
    let work: CanonicalFlockCatalogProjection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundStyle(Design.agentMessage)
                    Text(work.sessions.first?.title ?? "Unattached Work")
                        .font(.system(size: 16, weight: .semibold))
                    if let attention = work.attentionStatus.attention,
                       work.attentionStatus.requirement == .required {
                        Chip(text: attention.rawValue, symbol: "exclamationmark.bubble",
                             tint: Design.warning, filled: true)
                    } else if work.attentionStatus.requirement == .unknown {
                        Chip(text: "attention unknown", symbol: "questionmark.bubble",
                             tint: Design.warning)
                    }
                }
                Card("Canonical Work", symbol: "checkmark.seal") {
                    VStack(alignment: .leading, spacing: 5) {
                        DetailRow(label: "Work", value: work.id, mono: true)
                        DetailRow(label: "Host",
                                  value: work.workHost?.workHostID ?? "unknown", mono: true)
                        DetailRow(label: "Lifecycle",
                                  value: work.lifecycle?.rawValue ?? "unknown")
                        DetailRow(label: "Execution",
                                  value: work.execution?.rawValue ?? "unknown")
                        DetailRow(label: "Model", value: work.modelID ?? "unknown", mono: true)
                        DetailRow(label: "Children",
                                  value: work.childLifecycleAvailable
                                    ? "\(work.children.count)" : "unknown")
                    }
                }
                if !work.sessions.isEmpty {
                    Card("Attached Sessions", symbol: "bubble.left.and.text.bubble.right") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(work.sessions) { link in
                                HStack {
                                    Text(link.title).font(.system(size: 11))
                                    Spacer()
                                    Text(link.attention?.rawValue ?? "attention unknown")
                                        .font(Design.mono(9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !work.childLifecycleAvailable {
                    Card("Projection status", symbol: "exclamationmark.triangle") {
                        Text(work.unavailableReason ?? "Child lifecycle is unavailable")
                            .font(.system(size: 11)).foregroundStyle(Design.warning)
                        if !work.unknownDomains.isEmpty {
                            Text("Unknown domains: "
                                 + work.unknownDomains.map(\.rawValue).joined(separator: ", "))
                                .font(Design.mono(9)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(Design.gutter)
        }
    }
}

// MARK: - Tree row

struct AgentNodeRow: View {
    var node: AgentNode
    var depth: Int
    @Binding var selectedID: String?
    @Binding var expanded: Set<String>

    private var rowID: String {
        LegacyFlockIdentity.rowID(parentSessionID: node.parentSessionID, childID: node.id)
    }
    private var isExpanded: Bool { expanded.contains(rowID) }
    private var isSelected: Bool { selectedID == rowID }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if !node.children.isEmpty {
                    Button {
                        if isExpanded { expanded.remove(rowID) } else { expanded.insert(rowID) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 11)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Spacer().frame(width: 11)
                }

                statusDot

                Button {
                    selectedID = rowID
                } label: {
                    HStack(spacing: 6) {
                        Text(node.name)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        if !node.children.isEmpty {
                            Chip(text: "\(node.children.count)", tint: Design.agentMessage)
                        }
                        Spacer(minLength: 4)
                        if let m = node.model {
                            Text(m).font(Design.mono(9)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Text(Fmt.duration(node.duration))
                            .font(Design.numeric(9)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSelected ? Design.accentSoft : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 15)

            if isExpanded {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                    AgentNodeRow(
                        node: child, depth: depth + 1,
                        selectedID: $selectedID, expanded: $expanded)
                }
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if node.isRunning {
            PulseDot(color: Design.success)
        } else if node.isFailed {
            Circle().fill(Design.danger).frame(width: 7, height: 7)
        } else if node.isComplete {
            Circle().fill(Design.accent.opacity(0.6)).frame(width: 7, height: 7)
        } else {
            Circle().fill(Color.secondary.opacity(0.28)).frame(width: 7, height: 7)
        }
    }
}

// MARK: - Fan-out timeline

/// A compact time axis of one fan-out.
///
/// The question this answers — "did those twelve agents actually run in parallel, or did
/// they queue?" — is unanswerable from a transcript, and matters a great deal when you are
/// paying for the parallelism.
struct FanoutTimeline: View {
    var nodes: [AgentNode]
    @Binding var selectedID: String?

    private var bounds: (start: Date, end: Date)? {
        let starts = nodes.map(\.createdAt).filter { $0 > .distantPast }
        let ends = nodes.map(\.updatedAt).filter { $0 > .distantPast }
        guard let s = starts.min(), let e = ends.max(), e > s else { return nil }
        return (s, e)
    }

    var body: some View {
        if let bounds, nodes.count > 1 {
            let span = bounds.end.timeIntervalSince(bounds.start)
            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(nodes.prefix(24).enumerated()), id: \.offset) { _, node in
                            let offset = max(0, node.createdAt.timeIntervalSince(bounds.start)) / span
                            let width = max(0.006, node.duration / span)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.07))
                                Capsule()
                                    .fill(barColor(node))
                                    .frame(width: max(3, geo.size.width * width))
                                    .offset(x: geo.size.width * offset)
                            }
                            .frame(height: 5)
                            .onTapGesture {
                                selectedID = LegacyFlockIdentity.rowID(
                                    parentSessionID: node.parentSessionID, childID: node.id)
                            }
                            .help("\(node.name) · \(Fmt.duration(node.duration)) · \(node.status)")
                        }
                    }
                }
                .frame(height: CGFloat(min(24, nodes.count)) * 7)

                HStack {
                    Text(Fmt.clock(bounds.start))
                    Spacer()
                    Text("\(Fmt.duration(span)) span")
                    Spacer()
                    Text(Fmt.clock(bounds.end))
                }
                .font(Design.mono(8.5))
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
        }
    }

    private func barColor(_ node: AgentNode) -> Color {
        if selectedID == LegacyFlockIdentity.rowID(
            parentSessionID: node.parentSessionID, childID: node.id) { return Design.accent }
        if node.isRunning { return Design.success.opacity(0.8) }
        if node.isFailed { return Design.danger.opacity(0.8) }
        return Design.agentMessage.opacity(0.55)
    }
}

// MARK: - Node detail

struct AgentNodeDetail: View {
    @Environment(AppModel.self) private var model
    var node: AgentNode

    @State private var summary: SessionSummary?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                Card("Instructions", symbol: "text.quote") {
                    if node.prompt.isEmpty {
                        Text("No prompt recorded — this child was found in the spawn ledger "
                            + "but never wrote a status record of its own.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text(node.prompt)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !node.spawnCode.isEmpty {
                    Card("Spawn code", symbol: "chevron.left.forwardslash.chevron.right") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("The Python cell that created this child — usually spawning "
                                + "several siblings at once.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            CodeBlock(text: node.spawnCode, language: "python",
                                      maxLines: 20, tint: Design.tool, syntaxHighlight: true)
                        }
                    }
                }

                Card("Facts", symbol: "info.circle") {
                    VStack(alignment: .leading, spacing: 5) {
                        DetailRow(label: "Child id", value: node.id, mono: true)
                        DetailRow(label: "Status", value: node.status,
                                  tint: node.isRunning ? Design.success
                                    : node.isFailed ? Design.danger : nil)
                        DetailRow(label: "Model", value: node.modelLabel, mono: true)
                        DetailRow(label: "Depth", value: "\(node.depth) of max \(node.maxDepth)")
                        DetailRow(label: "Created", value: Fmt.timestamp(node.createdAt))
                        DetailRow(label: "Updated", value: Fmt.timestamp(node.updatedAt))
                        DetailRow(label: "Duration", value: Fmt.duration(node.duration))
                        DetailRow(label: "Session", value: node.sessionID, mono: true)
                        DetailRow(label: "Parent", value: node.parentSessionID, mono: true)
                    }
                }

                if let s = summary {
                    Card("What it did", symbol: "checklist") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                StatTile(label: "turns", value: "\(s.counts.assistant)")
                                StatTile(label: "tools", value: "\(s.counts.toolCalls)")
                                StatTile(label: "errors", value: "\(s.counts.toolErrors)",
                                         tint: s.counts.toolErrors > 0 ? Design.danger : .secondary)
                                StatTile(label: "tokens", value: Fmt.tokens(s.usage.totalTokens))
                            }
                            if !s.lastAssistantText.isEmpty {
                                Divider().opacity(0.5)
                                Text("LAST THING IT SAID")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Text(s.lastAssistantText)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else if loading {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Reading the child's transcript…").font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if !node.children.isEmpty {
                    Card("Its own children", symbol: "arrow.turn.down.right") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(node.children) { child in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(child.isRunning ? Design.success
                                            : Color.secondary.opacity(0.3))
                                        .frame(width: 6, height: 6)
                                    Text(child.name).font(.system(size: 11))
                                    Spacer()
                                    Text(child.status).font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Design.gutter)
        }
        .task(id: node.id) { await loadSummary() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if node.isRunning { PulseDot() }
                Text(node.name)
                    .font(.system(size: 16, weight: .semibold))
                Chip(text: node.status,
                     tint: node.isRunning ? Design.success
                        : node.isFailed ? Design.danger : .secondary,
                     filled: node.isRunning)
                Spacer()
            }
            HStack(spacing: 7) {
                Button {
                    Task { await model.loadChildTranscript(node: node) }
                    model.section = .sessions
                } label: {
                    Label("Open transcript", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([node.sessionFile])
                } label: {
                    Label("Reveal", systemImage: "folder").font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.prompt, forType: .string)
                } label: {
                    Label("Copy prompt", systemImage: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(node.prompt.isEmpty)
            }
        }
    }

    private func loadSummary() async {
        loading = true
        summary = nil
        let url = node.sessionFile
        let result = await Task.detached(priority: .userInitiated) {
            SessionCatalog.summarize(fileURL: url)
        }.value
        summary = result
        loading = false
    }
}
