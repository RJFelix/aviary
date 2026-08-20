import SwiftUI
import AppKit
import AviaryCore

/// The sub-agent view: who spawned whom, with what instructions, and how it went.
///
/// The harness can recurse — an agent calls `rlm(...)` and gets a child with its own
/// kernel, its own transcript, and its own children. In a terminal that structure is
/// invisible: you see one stream of text and a lot of `agent_message` traffic. This screen
/// is the reason a GUI is worth building for this harness at all.
struct FlockView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedNodeID: String?
    @State private var expanded: Set<String> = []
    @State private var showOnlyRunning = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                summaryBar
                Divider()
                if roots.isEmpty {
                    EmptyStateView(
                        symbol: "bird",
                        title: "No sub-agents yet",
                        message: "When an agent calls rlm(...) to spawn children, the whole "
                            + "tree shows up here — each child's prompt, model, status, and "
                            + "transcript.")
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

    private var roots: [(session: SessionSummary?, sessionID: String, nodes: [AgentNode])] {
        model.tree.byParentSession
            .map { key, value in
                (session: model.sessions.first { $0.id == key }, sessionID: key, nodes: value)
            }
            .filter { entry in
                guard showOnlyRunning else { return true }
                return entry.nodes.contains { $0.flattened.contains(where: \.isRunning) }
            }
            .sorted { a, b in
                let aTime = a.nodes.map(\.updatedAt).max() ?? .distantPast
                let bTime = b.nodes.map(\.updatedAt).max() ?? .distantPast
                return aTime > bTime
            }
    }

    private var selectedNode: AgentNode? {
        guard let id = selectedNodeID else { return nil }
        return model.tree.allNodes.first { $0.id == id }
    }

    private var summaryBar: some View {
        HStack(spacing: 14) {
            StatTile(
                label: "sub-agents", value: "\(model.tree.allNodes.count)",
                symbol: "bird.fill", tint: Design.agentMessage)
            StatTile(
                label: "running", value: "\(model.tree.runningCount)",
                symbol: "bolt.fill",
                tint: model.tree.runningCount > 0 ? Design.success : .secondary)
            StatTile(
                label: "fan-outs", value: "\(model.tree.byParentSession.count)",
                caption: "parent sessions", symbol: "arrow.triangle.branch")
            StatTile(
                label: "max depth",
                value: "\(model.tree.allNodes.map(\.depth).max() ?? 0)",
                symbol: "arrow.down.to.line")
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
                ForEach(roots, id: \.sessionID) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
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

                        FanoutTimeline(nodes: entry.nodes.flatMap(\.flattened),
                                       selectedID: $selectedNodeID)

                        ForEach(entry.nodes) { node in
                            AgentNodeRow(
                                node: node,
                                depth: 0,
                                selectedID: $selectedNodeID,
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
            .padding(Design.gutter)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if let node = selectedNode {
            AgentNodeDetail(node: node)
        } else {
            EmptyStateView(
                symbol: "sidebar.right",
                title: "Pick a sub-agent",
                message: "Its instructions, the code that spawned it, its model, and its "
                    + "own transcript are all recorded.")
        }
    }
}

// MARK: - Tree row

struct AgentNodeRow: View {
    var node: AgentNode
    var depth: Int
    @Binding var selectedID: String?
    @Binding var expanded: Set<String>

    private var isExpanded: Bool { expanded.contains(node.id) }
    private var isSelected: Bool { selectedID == node.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if !node.children.isEmpty {
                    Button {
                        if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
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
                    selectedID = node.id
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
                ForEach(node.children) { child in
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
                        ForEach(nodes.prefix(24)) { node in
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
                            .onTapGesture { selectedID = node.id }
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
        if selectedID == node.id { return Design.accent }
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
