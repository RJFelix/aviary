import SwiftUI
import AviaryCore

/// Aviary's visual language.
///
/// The app shows one thing above all: a lot of dense, machine-generated text — Python
/// cells, tracebacks, streamed prose, token counts. So the palette is deliberately quiet
/// and the hierarchy is carried by *role colour* rather than decoration: you should be able
/// to tell a user turn from a model turn from a tool cell at a glance, from across the
/// desk, without reading a word.
enum Design {
    // MARK: Palette

    /// Signature accent. Teal reads as neither "success green" nor "link blue", which
    /// leaves both free to mean something.
    static let accent = adaptive(light: (0.00, 0.42, 0.41), dark: (0.19, 0.70, 0.69))
    static let accentSoft = accent.opacity(0.14)

    /// Role colours. Each has a full-strength version for glyphs and rules, and a wash for
    /// backgrounds.
    static let user = adaptive(light: (0.17, 0.34, 0.76), dark: (0.47, 0.65, 1.00))
    static let assistant = adaptive(light: (0.47, 0.30, 0.79), dark: (0.73, 0.60, 1.00))
    static let tool = adaptive(light: (0.06, 0.40, 0.27), dark: (0.25, 0.72, 0.53))
    static let bash = adaptive(light: (0.45, 0.38, 0.17), dark: (0.76, 0.69, 0.43))
    static let agentMessage = adaptive(light: (0.62, 0.29, 0.08), dark: (0.95, 0.60, 0.30))
    static let system = Color.secondary

    static let danger = adaptive(light: (0.72, 0.16, 0.14), dark: (0.99, 0.50, 0.46))
    static let warning = adaptive(light: (0.54, 0.32, 0.00), dark: (0.90, 0.62, 0.13))
    static let success = adaptive(light: (0.08, 0.43, 0.21), dark: (0.23, 0.72, 0.42))
    static let thinking = adaptive(light: (0.40, 0.36, 0.54), dark: (0.69, 0.63, 0.82))

    /// Semantic text and glyphs need a darker ink on light surfaces, not the same neon hue.
    private static func adaptive(
        light: (Double, Double, Double), dark: (Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    /// The surface code sits on. Derived from `textBackgroundColor` rather than fixed, so it
    /// tracks the system appearance instead of needing a light and a dark constant.
    static let codeBackground = Color(nsColor: .textBackgroundColor).opacity(0.55)

    // MARK: Metrics

    static let cardRadius: CGFloat = 10
    static let cardPadding: CGFloat = 14
    static let gutter: CGFloat = 16
    static let hairline: CGFloat = 1

    // MARK: Type

    /// Code and any number you might compare to another number get tabular monospace.
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func numeric(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let sectionTitle = Font.system(size: 11, weight: .semibold)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let metric = Font.system(size: 26, weight: .medium, design: .rounded)
}

// MARK: - Role styling

extension TranscriptItem.Kind {
    var color: Color {
        switch self {
        case .user: return Design.user
        case .assistant: return Design.assistant
        case .tool: return Design.tool
        case .bash: return Design.bash
        case .agentMessage: return Design.agentMessage
        case .custom: return Design.system
        case .compaction: return Design.warning
        case .branchSummary: return Design.warning
        case .stateChange: return Design.system
        case .note: return Design.system
        }
    }

    var symbol: String {
        switch self {
        case .user: return "person.fill"
        case .assistant: return "sparkle"
        case .tool: return "terminal.fill"
        case .bash: return "chevron.left.forwardslash.chevron.right"
        case .agentMessage: return "arrow.left.arrow.right.circle.fill"
        case .custom: return "puzzlepiece.extension.fill"
        case .compaction: return "rectangle.compress.vertical"
        case .branchSummary: return "arrow.triangle.branch"
        case .stateChange: return "slider.horizontal.3"
        case .note: return "info.circle"
        }
    }

    var label: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Model"
        case .tool: return "Tool"
        case .bash: return "Shell"
        case .agentMessage: return "Agent message"
        case .custom: return "Extension"
        case .compaction: return "Compaction"
        case .branchSummary: return "Branch summary"
        case .stateChange: return "Setting"
        case .note: return "Aviary"
        }
    }
}

// MARK: - Reusable surfaces

/// The standard panel. One rounded rect, one hairline, no shadow — shadows on a dense
/// screen just add mud.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var accessory: AnyView?
    @ViewBuilder var content: () -> Content

    init(
        _ title: String? = nil,
        symbol: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || accessory != nil {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Design.accent)
                    }
                    if let title {
                        Text(title.uppercased())
                            .font(Design.sectionTitle)
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let accessory { accessory }
                }
            }
            content()
        }
        .padding(Design.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: Design.hairline)
        )
    }
}

/// A headline number with a label and optional trend line. The dashboard's unit of meaning.
struct StatTile: View {
    var label: String
    var value: String
    var caption: String?
    var symbol: String?
    var tint: Color = Design.accent
    var emphasis: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: emphasis ? 27 : 21, weight: .medium, design: .rounded))
                .foregroundStyle(emphasis ? tint : .primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small capsule tag. Used for models, providers, states, counts.
struct Chip: View {
    var text: String
    var symbol: String?
    var tint: Color = .secondary
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .foregroundStyle(filled ? .white : tint)
        .background(
            Capsule().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.25), lineWidth: 0.5)
        )
    }
}

/// Set when the UI is being rasterized rather than displayed.
///
/// A `repeatForever` animation never lets the view hierarchy reach a settled state, and a
/// window that never settles never draws — offscreen capture of a screen containing one
/// comes back permanently blank. Anything perpetually animated checks this and holds still.
private struct StaticRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staticRendering: Bool {
        get { self[StaticRenderingKey.self] }
        set { self[StaticRenderingKey.self] = newValue }
    }
}

/// A live indicator that actually pulses, because "is this still running?" is the single
/// most frequent question a person asks this app.
struct PulseDot: View {
    var color: Color = Design.success
    var active: Bool = true
    @Environment(\.staticRendering) private var staticRendering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    private var animates: Bool { active && !staticRendering && !reduceMotion }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(color.opacity(animates ? 0.55 : 0), lineWidth: 2)
                    .scaleEffect(phase ? 2.4 : 1)
                    .opacity(phase ? 0 : 1)
            )
            .overlay(
                // Still legible when motion is off: a ring instead of a pulse.
                Circle()
                    .stroke(color.opacity(!animates && active ? 0.45 : 0), lineWidth: 1.5)
                    .frame(width: 13, height: 13)
            )
            .animation(
                animates
                    ? .easeOut(duration: 1.5).repeatForever(autoreverses: false)
                    : .default,
                value: phase)
            .onAppear { if animates { phase = true } }
            .onChange(of: animates) { _, now in phase = now }
    }
}

/// Monospaced block with a copy button, optional language label, and a collapse control
/// for the long ones. Tool output in this harness is routinely thousands of lines.
struct CodeBlock: View {
    var text: String
    var language: String?
    var maxLines: Int = 18
    var tint: Color = Design.tool
    var syntaxHighlight: Bool = false

    @State private var expanded = false
    @State private var copied = false

    private var lines: [String] { text.components(separatedBy: "\n") }
    private var isTruncatable: Bool { lines.count > maxLines }
    private var shown: String {
        guard isTruncatable, !expanded else { return text }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let language {
                    Text(language)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                }
                Spacer()
                Text("\(lines.count) line\(lines.count == 1 ? "" : "s")")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Design.success : .secondary)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
                .accessibilityValue(copied ? "Complete" : "Ready")
                .help("Copy")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if syntaxHighlight {
                        Text(PythonHighlighter.highlight(shown))
                    } else {
                        Text(shown)
                    }
                }
                .font(Design.mono(11.5))
                .textSelection(.enabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isTruncatable {
                Divider().opacity(0.5)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                        Text(expanded
                            ? "Collapse"
                            : "Show \(lines.count - maxLines) more lines")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .accessibilityLabel(
                    expanded
                    ? "Collapse code"
                    : "Show more code")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows or hides the remaining lines")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Design.codeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }
}

/// Very light Python colouring.
///
/// Deliberately not a real parser: a lexer good enough to make a cell scannable is a few
/// rules, and a wrong-but-pretty highlight is worse than none. Keywords, strings,
/// comments, numbers. Nothing else.
enum PythonHighlighter {
    private static let keywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
        "False", "try", "while", "with", "yield", "self", "print",
    ]

    static func highlight(_ source: String) -> AttributedString {
        var out = AttributedString()
        for (i, line) in source.components(separatedBy: "\n").enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += highlightLine(line)
        }
        return out
    }

    private static func highlightLine(_ line: String) -> AttributedString {
        // A comment swallows the rest of the line — unless it's inside a string, which is
        // the one case this simple scanner accepts getting wrong.
        if let hash = line.firstIndex(of: "#"),
           !line[line.startIndex..<hash].contains("\"") ,
           !line[line.startIndex..<hash].contains("'")
        {
            var head = highlightCode(String(line[line.startIndex..<hash]))
            var comment = AttributedString(String(line[hash...]))
            comment.foregroundColor = .secondary
            head += comment
            return head
        }
        return highlightCode(line)
    }

    private static func highlightCode(_ text: String) -> AttributedString {
        var out = AttributedString()
        var token = ""
        var inString: Character?

        func flushToken() {
            guard !token.isEmpty else { return }
            var piece = AttributedString(token)
            if keywords.contains(token) {
                piece.foregroundColor = Design.assistant
            } else if Double(token) != nil {
                piece.foregroundColor = Design.bash
            }
            out += piece
            token = ""
        }

        for ch in text {
            if let quote = inString {
                token.append(ch)
                if ch == quote {
                    var piece = AttributedString(token)
                    piece.foregroundColor = Design.tool
                    out += piece
                    token = ""
                    inString = nil
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                flushToken()
                inString = ch
                token.append(ch)
                continue
            }
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." {
                token.append(ch)
            } else {
                flushToken()
                out += AttributedString(String(ch))
            }
        }
        if inString != nil {
            var piece = AttributedString(token)
            piece.foregroundColor = Design.tool
            out += piece
        } else {
            flushToken()
        }
        return out
    }
}

/// A row of label/value pairs, for detail panes and inspectors.
struct DetailRow: View {
    var label: String
    var value: String
    var mono: Bool = false
    var tint: Color?
    var selectable: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(mono ? Design.mono(11) : .system(size: 11.5))
            .foregroundStyle(tint ?? .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Empty state with a suggested action. Every list in the app has one.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        // Padding inside the greedy frame, never outside it. Reversed, the frame expands to
        // the proposed height and *then* padding adds 80pt to it, so the view reports back
        // more than it was offered; the parent re-proposes that, and the height runs away —
        // measured at 3040pt and still climbing inside a 963pt pane. The visible symptom is
        // not a too-tall empty state but a stack so oversized that everything above it is
        // clipped out of the window, which reads as "the header is missing".
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A horizontal proportion bar — used for context-window pressure and cache hit rate,
/// where the ratio matters more than either number.
struct RatioBar: View {
    var fraction: Double
    var tint: Color = Design.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Banner for a condition the user should act on. Carries the remedy, not just the alarm.
struct NoticeBanner: View {
    enum Level { case info, warning, danger, success }

    var level: Level
    var title: String
    var message: String?
    var actionLabel: String?
    var action: (() -> Void)?

    private var tint: Color {
        switch level {
        case .info: return Design.accent
        case .warning: return Design.warning
        case .danger: return Design.danger
        case .success: return Design.success
        }
    }

    private var symbol: String {
        switch level {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.09)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1))
        // Keep the remedy button independently reachable; the title/message already carry
        // the state in words, so VoiceOver never has to infer it from the banner tint.
        .accessibilityElement(children: .contain)
    }
}
