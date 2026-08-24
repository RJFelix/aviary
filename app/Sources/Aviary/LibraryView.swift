import SwiftUI
import AppKit
import AviaryCore

/// Skills, prompt templates, extensions, and packages — with every directory that was
/// searched, including the empty ones.
///
/// "Why isn't my skill loading?" is a question about paths and precedence. The harness can
/// list what it loaded; it cannot easily tell you what it *looked at*. So this screen shows
/// both, and marks which copy of a same-named skill actually wins.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .builtins
    @State private var search = ""
    @State private var selectedSkill: SkillEntry?
    @State private var selectedBuiltin: String?
    /// Shared by every chart on the screen, so switching tabs does not switch time window.
    @State private var window = 30

    enum Tab: String, CaseIterable, Identifiable {
        case builtins = "Builtins"
        case skills = "Skills"
        case prompts = "Prompts"
        case extensions = "Extensions"
        case packages = "Packages"
        case sources = "Search paths"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .builtins: return "curlybraces"
            case .skills: return "wand.and.stars"
            case .prompts: return "text.badge.plus"
            case .extensions: return "puzzlepiece.extension"
            case .packages: return "shippingbox"
            case .sources: return "folder.badge.questionmark"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Label(t.rawValue, systemImage: t.symbol).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                Spacer(minLength: 10)

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    TextField("Filter", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .frame(width: 150)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.08)))

                Button {
                    model.refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Design.gutter)
        .padding(.vertical, 9)
        .background(.background.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .builtins:
            BuiltinsPane(search: search, selected: $selectedBuiltin, window: $window)
        case .skills: skillsPane
        case .prompts: promptsPane
        case .extensions: extensionsPane
        case .packages: packagesPane
        case .sources: sourcesPane
        }
    }

    // MARK: Skills

    private var skills: [SkillEntry] {
        let q = search.lowercased()
        guard !q.isEmpty else { return model.library.skills }
        return model.library.skills.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private var skillsPane: some View {
        HSplitView {
            Group {
                if skills.isEmpty {
                    EmptyStateView(
                        symbol: "wand.and.stars",
                        title: "No skills discovered",
                        message: "Skills come from your agent directory, project "
                            + "`.agents/skills`, installed packages, and the engine's own "
                            + "bundle. The Search paths tab shows every place Aviary looked.")
                } else {
                    List(selection: $selectedSkill) {
                        ForEach(skills) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(s.name).font(.system(size: 12, weight: .medium))
                                    if s.hasPythonBacking {
                                        Chip(text: "python", symbol: "cube", tint: Design.tool)
                                    }
                                    if let used = model.libraryUsage.skill(named: s.name),
                                       used.calls > 0
                                    {
                                        Chip(text: "\(used.calls)×", symbol: "arrow.up.right",
                                             tint: Design.accent)
                                    }
                                    Spacer()
                                    Text(s.sourceLabel)
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                if !s.description.isEmpty {
                                    Text(s.description)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 3)
                            .tag(s)
                        }
                    }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds()
                }
            }
            .frame(minWidth: 280, idealWidth: 380, maxWidth: 560)

            Group {
                if let s = selectedSkill {
                    SkillDetail(
                        skill: s,
                        usage: model.libraryUsage.skill(named: s.name),
                        scanned: model.libraryUsageScanned,
                        window: $window)
                } else {
                    EmptyStateView(
                        symbol: "doc.text",
                        title: "Pick a skill",
                        message: "Its full instructions, frontmatter, and source path.")
                }
            }
            .frame(minWidth: 360)
        }
    }

    // MARK: Prompts

    private var promptsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let items = model.library.prompts.filter {
                    search.isEmpty || $0.name.lowercased().contains(search.lowercased())
                }
                if items.isEmpty {
                    EmptyStateView(
                        symbol: "text.badge.plus", title: "No prompt templates",
                        message: "A `.md` file in a package's `prompts/` directory or your "
                            + "agent directory becomes a slash command.")
                } else {
                    ForEach(items) { p in
                        Card(p.name, symbol: "text.badge.plus",
                             accessory: AnyView(
                                Button("Open") { NSWorkspace.shared.open(p.url) }
                                    .buttonStyle(.link).font(.system(size: 10))))
                        {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.firstLine)
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    Chip(text: p.sourceLabel, tint: .secondary)
                                    Chip(text: Fmt.bytes(p.byteSize), tint: .secondary)
                                    Spacer()
                                    Text(p.url.path).font(Design.mono(9))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                }
                NoUsageFootnote(subject: "template expansions happen before the model sees "
                    + "the prompt and")
            }
            .padding(Design.gutter)
        }
    }

    // MARK: Extensions

    private var extensionsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let items = model.library.extensions.filter {
                    search.isEmpty || $0.name.lowercased().contains(search.lowercased())
                }
                if items.isEmpty {
                    EmptyStateView(
                        symbol: "puzzlepiece.extension", title: "No extensions",
                        message: "Extensions are `.ts`/`.js` files in a package's "
                            + "`extensions/` directory. They can transform input, inject "
                            + "context, and register their own commands.")
                } else {
                    ForEach(items) { e in
                        Card(e.name, symbol: "puzzlepiece.extension.fill",
                             accessory: AnyView(
                                Button("Open") { NSWorkspace.shared.open(e.url) }
                                    .buttonStyle(.link).font(.system(size: 10))))
                        {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 5) {
                                    Chip(text: e.sourceLabel, tint: .secondary)
                                    Chip(text: Fmt.bytes(e.byteSize), tint: .secondary)
                                    Spacer()
                                }
                                if e.hooks.isEmpty {
                                    Text("No recognised event hooks found in the source.")
                                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                } else {
                                    HStack(spacing: 4) {
                                        ForEach(e.hooks, id: \.self) { h in
                                            Chip(text: h, tint: hookTint(h))
                                        }
                                        Spacer()
                                    }
                                }
                                if e.hooks.contains("before_agent_start") {
                                    Text("`before_agent_start` fires once per agent iteration, "
                                        + "not once per user prompt — an extension that injects "
                                        + "context there must be idempotent per prompt or it "
                                        + "will re-inject on every tool-call resume and "
                                        + "eventually stall the run.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Design.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(e.url.path).font(Design.mono(9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                NoUsageFootnote(subject: "hooks fire outside the conversation and")
            }
            .padding(Design.gutter)
        }
    }

    private func hookTint(_ hook: String) -> Color {
        switch hook {
        case "before_agent_start": return Design.warning
        case "input": return Design.user
        case "resources_discover": return Design.tool
        default: return .secondary
        }
    }

    // MARK: Packages

    private var packagesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.library.packages.isEmpty {
                    EmptyStateView(
                        symbol: "shippingbox", title: "No packages installed",
                        message: "Packages are listed in settings.json. A local-path package "
                            + "is a live reference — files added to it are picked up without "
                            + "reinstalling.")
                } else {
                    ForEach(model.library.packages) { p in
                        Card(p.name ?? p.spec, symbol: "shippingbox.fill") {
                            VStack(alignment: .leading, spacing: 5) {
                                DetailRow(label: "Spec", value: p.spec, mono: true)
                                if let url = p.resolvedURL {
                                    DetailRow(label: "Resolved", value: url.path, mono: true)
                                }
                                if let v = p.version { DetailRow(label: "Version", value: v) }
                                DetailRow(
                                    label: "Kind",
                                    value: p.isLocalPath
                                        ? "local path (live reference)" : "remote")
                                DetailRow(
                                    label: "Present",
                                    value: p.exists ? "yes" : "no",
                                    tint: p.exists ? nil : Design.danger)
                                HStack(spacing: 5) {
                                    Chip(text: "\(p.skillCount) skills", tint: Design.accent)
                                    Chip(text: "\(p.extensionCount) extensions", tint: Design.assistant)
                                    Chip(text: "\(p.promptCount) prompts", tint: Design.tool)
                                    Spacer()
                                    if let url = p.resolvedURL, p.exists {
                                        Button("Reveal") {
                                            NSWorkspace.shared.activateFileViewerSelecting([url])
                                        }
                                        .buttonStyle(.link).font(.system(size: 10))
                                    }
                                }
                                if !p.isLocalPath {
                                    Text("Aviary only inspects local-path packages; a remote "
                                        + "package's contents are resolved by the engine.")
                                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Design.gutter)
        }
    }

    // MARK: Sources

    private var sourcesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card("Every directory that was searched", symbol: "folder.badge.questionmark") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Listed in precedence order. When two directories hold a skill of "
                            + "the same name, the one nearer the top wins — and the loser is "
                            + "silently invisible, which is where the confusion usually lives.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                        ForEach(model.library.sources.sorted(by: { $0.precedence < $1.precedence })) { src in
                            HStack(spacing: 8) {
                                Image(systemName: src.exists
                                    ? (src.count > 0 ? "checkmark.circle.fill" : "circle")
                                    : "minus.circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(src.exists
                                        ? (src.count > 0 ? Design.success : Color.secondary)
                                        : Color.secondary.opacity(0.35))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(src.label).font(.system(size: 11, weight: .medium))
                                    Text(src.url.path)
                                        .font(Design.mono(9.5)).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(src.exists ? "\(src.count)" : "absent")
                                    .font(Design.numeric(10))
                                    .foregroundStyle(src.exists ? .secondary : .tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Card("Duplicate names", symbol: "doc.on.doc") {
                    // Shows only the winners, so a duplicate that lost is worth naming.
                    Text("Aviary dedupes by name the way the harness does, keeping the "
                        + "highest-precedence copy. \(model.library.skills.count) unique "
                        + "skills are loadable.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Design.gutter)
        }
    }
}

// MARK: - Skill detail

struct SkillDetail: View {
    var skill: SkillEntry
    var usage: LibraryUsage.Series?
    var scanned: Bool
    @Binding var window: Int
    @State private var body_text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(skill.name).font(.system(size: 17, weight: .semibold))
                        if skill.hasPythonBacking {
                            Chip(text: "python-backed", symbol: "cube", tint: Design.tool)
                        }
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(skill.url) }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([skill.url])
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 5) {
                        Chip(text: skill.sourceLabel, tint: Design.accent)
                        Chip(text: "\(skill.bodyLength) chars", tint: .secondary)
                        if !skill.allowedTools.isEmpty {
                            Chip(text: skill.allowedTools.joined(separator: ", "),
                                 symbol: "wrench", tint: Design.tool)
                        }
                        Spacer()
                    }
                    Text(skill.url.path)
                        .font(Design.mono(9.5)).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                Card("Reached for", symbol: "chart.bar.xaxis",
                     accessory: AnyView(WindowPicker(window: $window)))
                {
                    // A skill is credited when a cell names its *path*. Several of the
                    // bundled skills are called `edit`, `goal`, `compact` — ordinary words
                    // that would match half the corpus on a bare-name search.
                    VStack(alignment: .leading, spacing: 8) {
                        if !scanned {
                            Text("Reading the trajectories…")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        } else if let usage, usage.wasEverUsed {
                            UsageChart(days: usage.days(last: window), tint: Design.assistant,
                                       height: 96)
                            Text("\(usage.cells) cells across \(usage.sessions) session(s) "
                                + "referenced this skill's path.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        } else {
                            Text("No cell in the recorded history opened or ran anything from "
                                + "this skill's directory.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Card("Instructions", symbol: "doc.plaintext") {
                    if body_text.isEmpty {
                        Text("Empty or unreadable.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text(body_text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Design.gutter)
        }
        .task(id: skill.id) {
            let url = skill.url
            body_text = await Task.detached(priority: .userInitiated) { () -> String in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
                return Frontmatter.parse(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
        }
    }
}

/// Why two of these tabs have no chart.
///
/// Use is read back out of the trajectories, and a transcript records what the *model* did: the
/// cells it ran, and therefore the builtins and skill files those cells touched. A prompt
/// template is expanded before the model sees anything, and a hook fires outside the
/// conversation entirely — neither leaves a mark in the record, so a chart here would be
/// fabricated rather than sparse. Recording them is a change to the writer, not to this screen.
struct NoUsageFootnote: View {
    var subject: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            Text("No usage chart: \(subject) leave no trace in a transcript, so there is "
                + "nothing to count. Builtins and skills do, because the model's own cells "
                + "name them.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.top, 4)
    }
}
