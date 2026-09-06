import SwiftUI
import AppKit
import AviaryCore

private struct TranscriptViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TranscriptBottomPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Renders a transcript — read from disk or streaming live, identically.
struct TranscriptView: View {
    var items: [TranscriptItem]
    var searchQuery: String = ""
    var hideThinking: Bool = false
    var isStreaming: Bool = false
    var autoScroll: Bool = true
    var onSelect: ((TranscriptItem) -> Void)?

    @State private var scrollTarget: String?
    @State private var viewportHeight: CGFloat = 0
    @State private var bottomPosition: CGFloat = 0
    @State private var isAtBottom = true
    @State private var unreadCount = 0

    private var visible: [TranscriptItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            item.plainText.lowercased().contains(q)
                || (item.toolResultText?.lowercased().contains(q) ?? false)
                || (item.toolCall?.pythonCode?.lowercased().contains(q) ?? false)
                || (item.command?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visible) { item in
                            TranscriptRow(
                                item: item,
                                searchQuery: searchQuery,
                                hideThinking: hideThinking,
                                isLast: item.id == visible.last?.id && isStreaming,
                                onSelect: onSelect)
                                .id(item.id)
                        }
                        if isStreaming {
                            StreamingIndicator()
                                .id("__streaming_tail__")
                        }
                        Color.clear.frame(height: 8)
                            .id("__bottom__")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TranscriptBottomPositionKey.self,
                                    value: geometry.frame(in: .named("AviaryTranscriptScroll")).maxY)
                            })
                    }
                    .padding(.horizontal, Design.gutter)
                    .padding(.vertical, 14)
                }
                .coordinateSpace(name: "AviaryTranscriptScroll")
                .background(GeometryReader { geometry in
                    Color.clear.preference(
                        key: TranscriptViewportHeightKey.self,
                        value: geometry.size.height)
                })

                if !isAtBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                        unreadCount = 0
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                            if unreadCount > 0 {
                                Text("\(unreadCount) new")
                            }
                            Text("Jump to latest")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Design.accent)
                    .accessibilityLabel(unreadCount > 0
                        ? "Jump to latest, \(unreadCount) new transcript items"
                        : "Jump to latest")
                    .help("Jump to the latest transcript output")
                    .padding(.trailing, Design.gutter)
                    .padding(.bottom, 12)
                }
            }
            .onPreferenceChange(TranscriptViewportHeightKey.self) { height in
                viewportHeight = height
                updateBottomState()
            }
            .onPreferenceChange(TranscriptBottomPositionKey.self) { position in
                bottomPosition = position
                updateBottomState()
            }
            .onChange(of: items.count) { oldCount, newCount in
                let added = max(0, newCount - oldCount)
                guard added > 0 else { return }
                if autoScroll && isAtBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                    unreadCount = 0
                } else {
                    unreadCount += added
                }
            }
            .onChange(of: visible.last?.plainText.count ?? 0) { _, _ in
                guard autoScroll, isStreaming, isAtBottom else { return }
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
            .onChange(of: isAtBottom) { _, atBottom in
                if atBottom { unreadCount = 0 }
            }
            .onAppear {
                if autoScroll {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
        }
    }

    private func updateBottomState() {
        guard viewportHeight > 0 else { return }
        let atBottom = bottomPosition <= viewportHeight + 24
        if atBottom != isAtBottom { isAtBottom = atBottom }
    }
}

// MARK: - Row

struct TranscriptRow: View {
    var item: TranscriptItem
    var searchQuery: String
    var hideThinking: Bool
    var isLast: Bool
    var onSelect: ((TranscriptItem) -> Void)?

    @State private var showRaw = false

    /// Canonical projections use `.distantPast` only as an explicit missing-time sentinel. Never
    /// format it as though the host recorded a real wall-clock value.
    private var timestampLabel: String {
        item.timestamp == .distantPast ? "time unknown" : Fmt.clock(item.timestamp)
    }

    var body: some View {
        switch item.kind {
        case .user: userRow
        case .assistant: assistantRow
        case .tool: toolRow
        case .bash: bashRow
        case .agentMessage: agentMessageRow
        case .custom:
            // An artifact is a custom entry, but showing it as one would print the document's
            // location as grey machinery text — the least useful thing on screen about a file
            // somebody is meant to open.
            if let artifact = item.artifact { artifactRow(artifact) } else { customRow }
        case .compaction, .branchSummary: summaryRow
        case .stateChange, .note: inlineRow
        }
    }

    // MARK: Header

    private func header(
        _ label: String, tint: Color, symbol: String, trailing: AnyView? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(timestampLabel)
                .font(Design.mono(9.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            if let trailing { trailing }
            Button {
                showRaw.toggle()
            } label: {
                Image(systemName: "curlybraces")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showRaw ? Design.accent : Color.secondary.opacity(0.4))
            .accessibilityLabel(showRaw ? "Hide raw session entry" : "Show raw session entry")
            .accessibilityValue(showRaw ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the original session record for this row")
            .help(showRaw ? "Hide the raw session entry" : "Show the raw session entry")
            .opacity(item.raw == nil ? 0 : 1)
            .disabled(item.raw == nil)
        }
    }

    private var rawPane: some View {
        Group {
            if showRaw, let raw = item.raw {
                CodeBlock(text: raw.prettyPrinted, language: "session entry",
                          maxLines: 24, tint: .secondary)
            }
        }
    }

    // MARK: Kinds

    private var userRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            header("You", tint: Design.user, symbol: "person.fill")
            ForEach(item.blocks) { block in
                if case .text(let text) = block {
                    // A hook-injected context block is real context the model saw, but it
                    // is not what the person typed. Show it, collapsed, above the prompt.
                    let split = PromptText.split(text)
                    ForEach(split.injected) { injected in
                        InjectedContextBlock(block: injected)
                    }
                    // A prompt is written in markdown too — Ryan's prompts are mostly
                    // dashed lists — so it gets the same treatment as a reply rather than
                    // being shown as the only plain-text role in the transcript.
                    MarkdownText(text: split.userText, query: searchQuery)
                } else if case .image(let mime, let data) = block {
                    InlineImage(mimeType: mime, base64: data)
                }
            }
            rawPane
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle().fill(Design.user.opacity(0.5)).frame(width: 2.5)
        }
        .onTapGesture { onSelect?(item) }
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            header(
                item.model ?? "Model",
                tint: Design.assistant,
                symbol: "sparkle",
                trailing: AnyView(
                    HStack(spacing: 5) {
                        if let stop = item.stopReason, stop != "stop", stop != "toolUse" {
                            Chip(text: stop, tint: stop == "aborted" ? Design.warning : Design.danger)
                        }
                        if let r = item.usage?.reasoning, r > 0 {
                            Chip(text: Fmt.tokens(r), symbol: "brain", tint: Design.thinking)
                                .help("\(r) reasoning tokens, reported by the provider and "
                                    + "already counted inside output. On this route the "
                                    + "reasoning text itself is not returned — this count is "
                                    + "the only record that it happened.")
                        }
                        if let u = item.usage, !u.isEmpty {
                            Chip(text: Fmt.tokens(u.totalTokens), symbol: "number", tint: .secondary)
                                .help(usageTooltip(u))
                        }
                    }))

            ForEach(item.blocks) { block in
                switch block {
                case .thinking(let text):
                    if !hideThinking { ThinkingBlock(text: text) }
                case .text(let text):
                    MarkdownText(text: text, query: searchQuery)
                case .toolCall:
                    // Rendered as its own row so the code sits next to its output.
                    EmptyView()
                case .image(let mime, let data):
                    InlineImage(mimeType: mime, base64: data)
                }
            }

            if let err = item.errorMessage, !err.isEmpty {
                NoticeBanner(level: .danger, title: "Model error", message: err)
            }
            rawPane
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle().fill(Design.assistant.opacity(0.45)).frame(width: 2.5)
        }
        .onTapGesture { onSelect?(item) }
    }

    private var toolRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(
                item.toolCall?.name ?? "tool",
                tint: item.toolIsError ? Design.danger : Design.tool,
                symbol: item.toolIsError ? "exclamationmark.triangle.fill" : "terminal.fill",
                trailing: AnyView(
                    HStack(spacing: 5) {
                        if let d = item.toolDuration, d > 0.05 {
                            Chip(text: Fmt.duration(d), symbol: "clock", tint: .secondary)
                        }
                        if item.toolResultText == nil {
                            Chip(text: "running", tint: Design.warning)
                        }
                    }))

            if let code = item.toolCall?.pythonCode {
                CodeBlock(text: code, language: "python", maxLines: 22,
                          tint: Design.tool, syntaxHighlight: true)
            } else if let args = item.toolCall?.arguments, args.objectValue?.isEmpty == false {
                CodeBlock(text: args.prettyPrinted, language: item.toolCall?.name,
                          maxLines: 14, tint: Design.tool)
            }

            if let out = item.toolResultText, !out.isEmpty {
                CodeBlock(
                    text: out,
                    language: item.toolIsError ? "error" : "output",
                    maxLines: 16,
                    tint: item.toolIsError ? Design.danger : .secondary)
            } else if item.toolResultText?.isEmpty == true {
                Text("No output")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            if !item.toolResultImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(item.toolResultImages.enumerated()), id: \.offset) { _, img in
                            InlineImage(mimeType: img.mimeType, base64: img.base64, maxHeight: 220)
                        }
                    }
                }
            }
            rawPane
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill((item.toolIsError ? Design.danger : Design.tool).opacity(0.4))
                .frame(width: 2.5)
        }
        .onTapGesture { onSelect?(item) }
    }

    private var bashRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(
                "shell",
                tint: Design.bash,
                symbol: "chevron.left.forwardslash.chevron.right",
                trailing: AnyView(
                    Group {
                        if let code = item.exitCode, code != 0 {
                            Chip(text: "exit \(code)", tint: Design.danger)
                        }
                    }))
            if let cmd = item.command {
                CodeBlock(text: cmd, language: "sh", maxLines: 6, tint: Design.bash)
            }
            if !item.text.isEmpty {
                CodeBlock(text: item.text, language: "output", maxLines: 14, tint: .secondary)
            }
            rawPane
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle().fill(Design.bash.opacity(0.4)).frame(width: 2.5)
        }
    }

    private var agentMessageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(
                item.senderName.map { "from \($0)" } ?? "agent message",
                tint: Design.agentMessage,
                symbol: "arrow.left.arrow.right.circle.fill")
            // The provenance header is machine-generated routing metadata; the payload
            // after it is what a person wants to read.
            let parts = AgentMessageBody.split(item.text)
            if let meta = parts.header {
                DisclosureGroup {
                    Text(meta)
                        .font(Design.mono(10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Text("routing details")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            MarkdownText(text: parts.body, query: searchQuery)
            rawPane
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Design.agentMessage.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Design.agentMessage.opacity(0.25), lineWidth: 1))
    }

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            header(item.customType ?? "extension", tint: Design.system,
                   symbol: "puzzlepiece.extension.fill")
            if !item.text.isEmpty {
                Text(item.text.prefix(4000))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            rawPane
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2.5)
        }
    }

    /// A document the agent wrote, as a card rather than as its contents.
    ///
    /// The body is deliberately not shown: an artifact exists because several thousand words
    /// inline is the failure being fixed, and reproducing them here would undo it. What the
    /// card owes the reader is that one was made, what it is, and how to get to it.
    private func artifactRow(_ artifact: ArtifactNote) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            header(
                "artifact", tint: Design.accent, symbol: "doc.richtext.fill",
                trailing: AnyView(
                    HStack(spacing: 5) {
                        if !artifact.format.isEmpty {
                            Chip(text: artifact.format, tint: Design.accent)
                        }
                        if artifact.byteCount > 0 {
                            Chip(text: Fmt.bytes(artifact.byteCount), symbol: "doc",
                                 tint: .secondary)
                        }
                    }))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .textSelection(.enabled)
                    Text(artifact.path)
                        .font(Design.mono(9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 6)
                Button {
                    NSWorkspace.shared.open(artifact.url)
                } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Design.accent)
                .accessibilityLabel("Open artifact")
                .help("Open the artifact")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
                } label: {
                    Image(systemName: "folder").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Design.accent)
                .accessibilityLabel("Reveal artifact in Finder")
                .help("Reveal in Finder")
            }
            rawPane
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Design.accent.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Design.accent.opacity(0.25), lineWidth: 1))
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                Text(item.kind.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                if let u = item.usage, u.totalTokens > 0 {
                    Text("· \(Fmt.tokens(u.totalTokens)) tokens before")
                        .font(.system(size: 10))
                }
                Spacer()
                Text(timestampLabel).font(Design.mono(9.5))
            }
            .foregroundStyle(Design.warning)

            if !item.text.isEmpty {
                Text(item.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(14)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Design.warning.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Design.warning.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    private var inlineRow: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 8.5))
            Text(item.text)
                .font(.system(size: 10.5))
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Text(timestampLabel).font(Design.mono(9))
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 12)
    }

    private func usageTooltip(_ u: Usage) -> String {
        var parts = [
            "in \(Fmt.tokens(u.input))",
            "out \(Fmt.tokens(u.output))",
        ]
        if u.cacheRead > 0 { parts.append("cache read \(Fmt.tokens(u.cacheRead))") }
        if u.cacheWrite > 0 { parts.append("cache write \(Fmt.tokens(u.cacheWrite))") }
        if let r = u.reasoning, r > 0 { parts.append("reasoning \(Fmt.tokens(r))") }
        if u.cost.total > 0 { parts.append(Fmt.cost(u.cost.total)) }
        if let rate = u.cacheHitRate, rate > 0 { parts.append("\(Fmt.percent(rate)) cached") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pieces

/// Reasoning text, collapsed by default. Long, useful when you want it, noise when you don't.
struct ThinkingBlock: View {
    var text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "brain")
                        .font(.system(size: 9))
                    Text("thinking")
                        .font(.system(size: 10, weight: .medium))
                    // Reasoning is billed as output, so its size is the interesting part.
                    // Estimated from the text at four characters per token, because the
                    // provider reports one total for the whole message.
                    Text("· ≈\(Fmt.tokens(max(1, text.count / 4))) tokens")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    Text("· \(text.count) chars")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Design.thinking)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide thinking" : "Show thinking")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Reveals or hides the model's reasoning text")

            if expanded {
                Text(text)
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Design.thinking.opacity(0.3)).frame(width: 1.5)
                    }
            }
        }
    }
}

/// Model prose.
///
/// Kept as a name because it is used from several places; the rendering lives in
/// `MarkdownBody`, which parses block structure first and inline markdown within each block.
/// This used to be inline-only for the whole string, which meant a heading, a list or a
/// fenced block rendered as its own literal syntax.
struct MarkdownText: View {
    var text: String
    var query: String = ""

    var body: some View { MarkdownBody(text: text, query: query) }
}

/// Text with every occurrence of the search query highlighted.
struct HighlightedText: View {
    var text: String
    var query: String

    var body: some View {
        Text(attributed)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var out = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return out }
        var searchRange = out.startIndex..<out.endIndex
        while let found = out[searchRange].range(of: q, options: .caseInsensitive) {
            out[found].backgroundColor = Design.warning.opacity(0.35)
            out[found].inlinePresentationIntent = .stronglyEmphasized
            guard found.upperBound < out.endIndex else { break }
            searchRange = found.upperBound..<out.endIndex
        }
        return out
    }
}

/// A base64 image block from a tool result or a user attachment.
struct InlineImage: View {
    var mimeType: String
    var base64: String
    var maxHeight: CGFloat = 320

    var body: some View {
        if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           let image = NSImage(data: data)
        {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1))
        } else {
            Label("Unreadable image (\(mimeType))", systemImage: "photo.badge.exclamationmark")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }
}

struct StreamingIndicator: View {
    @Environment(\.staticRendering) private var staticRendering
    @State private var tick = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Design.assistant.opacity(tick % 3 == i ? 0.9 : 0.25))
                    .frame(width: 5, height: 5)
            }
            Text("working")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent is working")
        .accessibilityValue("Streaming response")
        .task {
            guard !staticRendering else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 320_000_000)
                tick += 1
            }
        }
    }
}

/// Splits an agent-to-agent message into its generated provenance header and the body the
/// sending agent actually wrote.
enum AgentMessageBody {
    static func split(_ text: String) -> (header: String?, body: String) {
        // The header block ends at the first blank line after the "Message id:" line.
        guard text.hasPrefix("[from "), let idRange = text.range(of: "Message id:") else {
            return (nil, text)
        }
        let afterID = text[idRange.upperBound...]
        guard let blank = afterID.range(of: "\n\n") else { return (nil, text) }
        let header = String(text[text.startIndex..<blank.lowerBound])
        let body = String(text[blank.upperBound...])
        return (header, body)
    }
}


/// A context block a hook prepended to the user's prompt, collapsed by default.
struct InjectedContextBlock: View {
    var block: PromptText.Block
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 9))
                    Text("injected: \(block.tag)")
                        .font(.system(size: 10, weight: .medium))
                    Text("· \(block.body.count) chars")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Design.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                expanded ? "Hide injected context" : "Show injected context")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Reveals or hides context added before the prompt")

            if expanded {
                Text(block.body)
                    .font(Design.mono(10.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Design.accent.opacity(0.3)).frame(width: 1.5)
                    }
            }
        }
    }
}
