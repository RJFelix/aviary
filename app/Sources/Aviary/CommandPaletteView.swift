import SwiftUI
import AppKit
import AviaryCore

/// ⌘K: one text field that reaches everything.
///
/// A dense tool accumulates screens faster than a person accumulates muscle memory for
/// them. The palette searches sessions, sub-agents, models, skills, and actions in one
/// list, so the answer to "where was that?" is always the same keystroke.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Int = 0
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id = UUID()
        var kind: Kind
        var title: String
        var subtitle: String
        var symbol: String
        var tint: Color
        var action: () -> Void

        enum Kind: String {
            case action = "Action"
            case section = "Go to"
            case session = "Session"
            case agent = "Sub-agent"
            case model = "Model"
            case skill = "Skill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("Search sessions, agents, models, skills, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(entries.indices.contains(selection) ? entries[selection] : nil) }
                    .onChange(of: query) { _, _ in selection = 0 }
                Text("esc")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 22)).foregroundStyle(.quaternary)
                    Text("Nothing matches “\(query)”")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                Button {
                                    run(entry)
                                } label: {
                                    PaletteRow(entry: entry, selected: index == selection)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                                .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 380)
                    .onChange(of: selection) { _, now in
                        proxy.scrollTo(now, anchor: .center)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                hint("↑↓", "navigate")
                hint("↵", "open")
                hint("⌘K", "toggle")
                Spacer()
                Text("\(entries.count) result\(entries.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .frame(width: 660)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) {
            selection = max(0, selection - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selection = min(entries.count - 1, selection + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.13)))
            Text(label).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }

    private func run(_ entry: Entry?) {
        guard let entry else { return }
        entry.action()
        dismiss()
    }

    // MARK: Entries

    private var entries: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Entry] = []

        // Actions and navigation come first when the query is short — that's when the user
        // is reaching for a place, not searching for content.
        for s in Section.visible where q.isEmpty || s.title.lowercased().contains(q)
            || s.subtitle.lowercased().contains(q)
        {
            out.append(Entry(
                kind: .section, title: s.title, subtitle: s.subtitle,
                symbol: s.symbol, tint: Design.accent,
                action: { model.section = s }))
        }

        for action in actions where q.isEmpty || action.title.lowercased().contains(q) {
            out.append(action)
        }

        if !q.isEmpty {
            for s in model.sessions where matches(s, q) {
                out.append(Entry(
                    kind: .session, title: s.title,
                    subtitle: "\(s.projectName) · \(Fmt.ago(s.updatedAt)) · "
                        + "\(Fmt.tokens(s.usage.totalTokens)) tokens",
                    symbol: s.isLive ? "dot.radiowaves.left.and.right" : "bubble.left.and.text.bubble.right",
                    tint: Design.user,
                    action: {
                        model.section = .sessions
                        model.select(session: s)
                    }))
                if out.count > 120 { break }
            }

            for node in model.tree.allNodes
            where node.name.lowercased().contains(q) || node.prompt.lowercased().contains(q) {
                out.append(Entry(
                    kind: .agent, title: node.name,
                    subtitle: "\(node.status) · \(node.modelLabel) · depth \(node.depth)",
                    symbol: "bird", tint: Design.agentMessage,
                    action: {
                        model.section = .flock
                        Task { await model.loadChildTranscript(node: node) }
                    }))
                if out.count > 160 { break }
            }

            for m in model.pickerModels where m.qualifiedID.lowercased().contains(q) {
                out.append(Entry(
                    kind: .model, title: m.qualifiedID,
                    subtitle: [
                        m.contextWindow.map { "\(Fmt.tokens($0)) context" },
                        m.reasoning ? "reasoning" : nil,
                        m.costInput.map { "$\($0)/M in" },
                    ].compactMap { $0 }.joined(separator: " · "),
                    symbol: "cpu", tint: Design.assistant,
                    action: {
                        model.section = .live
                        NotificationCenter.default.post(name: .aviaryNewRun, object: nil)
                    }))
                if out.count > 200 { break }
            }

            for skill in model.library.skills
            where skill.name.lowercased().contains(q) || skill.description.lowercased().contains(q) {
                out.append(Entry(
                    kind: .skill, title: skill.name,
                    subtitle: skill.description.isEmpty ? skill.sourceLabel : skill.description,
                    symbol: "wand.and.stars", tint: Design.tool,
                    action: { model.section = .library }))
                if out.count > 240 { break }
            }
        }

        return out
    }

    private func matches(_ s: SessionSummary, _ q: String) -> Bool {
        s.title.lowercased().contains(q)
            || s.firstPrompt.lowercased().contains(q)
            || s.projectName.lowercased().contains(q)
            || (s.model?.lowercased().contains(q) ?? false)
            || s.id.lowercased().contains(q)
    }

    private var actions: [Entry] {
        [
            Entry(kind: .action, title: "New run…",
                  subtitle: "Launch the engine and drive it from here",
                  symbol: "play.circle.fill", tint: Design.success,
                  action: {
                      model.section = .live
                      NotificationCenter.default.post(name: .aviaryNewRun, object: nil)
                  }),
            Entry(kind: .action, title: "Refresh everything",
                  subtitle: "Rescan transcripts, re-poll the daemon, reload the model catalog",
                  symbol: "arrow.clockwise", tint: Design.accent,
                  action: { Task { await model.refreshAll() } }),
            Entry(kind: .action, title: "Rescan sessions",
                  subtitle: "Re-read every transcript file",
                  symbol: "magnifyingglass", tint: Design.accent,
                  action: { Task { await model.refreshCatalog() } }),
            Entry(kind: .action, title: "Check the background service",
                  subtitle: "Handshake, ownership assertion, and process table",
                  symbol: "stethoscope", tint: Design.warning,
                  action: {
                      model.section = .health
                  }),
            Entry(kind: .action, title: "Toggle thinking blocks",
                  subtitle: model.hideThinking ? "Currently hidden" : "Currently shown",
                  symbol: "brain", tint: Design.thinking,
                  action: { model.hideThinking.toggle() }),
            Entry(kind: .action, title: "Reveal the agent directory",
                  subtitle: model.home.root.path,
                  symbol: "folder", tint: .secondary,
                  action: {
                      NSWorkspace.shared.activateFileViewerSelecting([model.home.root])
                  }),
            Entry(kind: .action, title: "Open models.json",
                  subtitle: "Edit providers by hand",
                  symbol: "doc.text", tint: .secondary,
                  action: { NSWorkspace.shared.open(model.modelsConfig.fileURL) }),
        ]
    }
}

struct PaletteRow: View {
    var entry: CommandPaletteView.Entry
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 12))
                .foregroundStyle(entry.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(entry.kind.rawValue)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Design.accentSoft : .clear))
        .contentShape(Rectangle())
    }
}
