import SwiftUI
import AppKit
import AviaryCore

/// What was actually sent to the model, decomposed.
///
/// The question this answers — "a two-message session charged me 17,000 input tokens; what
/// were they?" — has no answer anywhere else. The transcript holds messages; the system
/// prompt, every discovered AGENTS.md, the skill catalogue and the tool schemas are
/// assembled at request time and persisted nowhere. Aviary records them through the
/// harness's `before_provider_request` hook and breaks them apart here.
///
/// On sizes: characters are measured, tokens are estimated at four characters each. Where
/// the provider's real input count is known, each part's *share* — which is exact — is
/// multiplied through it, so the numbers shown are anchored to something billed rather than
/// to a heuristic. The distinction is on screen, not buried in a tooltip.
struct ContextBreakdownView: View {
    var analysis: PayloadAnalysis
    var actualInputTokens: Int?
    var recordedAt: Date?

    @State private var expanded: Set<String> = ["system", "skills"]
    @State private var inspecting: PayloadSegment?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                segmentList
                caveat
            }
            .padding(Design.gutter)
        }
        .sheet(item: $inspecting) { segment in
            SegmentTextSheet(segment: segment)
        }
    }

    // MARK: Header

    private var header: some View {
        Card("What was sent", symbol: "arrow.up.doc") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 14) {
                    StatTile(
                        label: actualInputTokens == nil ? "estimated input" : "billed input",
                        value: Fmt.tokens(actualInputTokens ?? analysis.estimatedTokens),
                        caption: actualInputTokens == nil
                            ? "no usage reported yet"
                            : "provider's own count",
                        symbol: "number",
                        tint: Design.accent,
                        emphasis: true)
                    Divider().frame(height: 40)
                    StatTile(
                        label: "payload size",
                        value: Fmt.bytes(analysis.totalCharacters),
                        caption: "≈\(Fmt.tokens(analysis.estimatedTokens)) tokens at 4 chars each",
                        symbol: "doc.text")
                    Divider().frame(height: 40)
                    StatTile(
                        label: "shape",
                        value: analysis.shape,
                        caption: analysis.modelID ?? "—",
                        symbol: "cpu")
                }
                if let recordedAt {
                    Text("Recorded \(Fmt.timestamp(recordedAt))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Segments

    private var segmentList: some View {
        Card("Composition", symbol: "chart.pie",
             accessory: AnyView(
                Text("largest first")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)))
        {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(analysis.segments) { segment in
                    SegmentRow(
                        segment: segment,
                        depth: 0,
                        payloadCharacters: analysis.totalCharacters,
                        actualTokens: actualInputTokens,
                        expanded: $expanded,
                        inspecting: $inspecting)
                }
            }
        }
    }

    private var caveat: some View {
        Card("Reading these numbers", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 5) {
                bullet("Character counts are measured. Token counts are estimated at four "
                    + "characters per token — the provider's tokenizer is not available here.")
                if actualInputTokens != nil {
                    bullet("The per-part token figures are each part's exact share of the "
                        + "payload multiplied by the provider's own input count, so they add "
                        + "up to something you were actually billed for.")
                } else {
                    bullet("No usage has come back for this request yet, so every token "
                        + "figure here is the raw estimate.")
                }
                bullet("Cached input is billed differently and is not distinguished here. A "
                        + "large, stable system prompt is usually mostly cache reads after "
                        + "the first turn — check the cache hit rate in the run's Tokens panel.")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(.tertiary).frame(width: 3, height: 3).padding(.top, 6)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Row

struct SegmentRow: View {
    var segment: PayloadSegment
    var depth: Int
    var payloadCharacters: Int
    var actualTokens: Int?
    @Binding var expanded: Set<String>
    @Binding var inspecting: PayloadSegment?

    private var isExpanded: Bool { expanded.contains(segment.id) }

    private var tokens: Int {
        guard let actualTokens else { return segment.estimatedTokens }
        return segment.scaledTokens(payloadCharacters: payloadCharacters, actualTokens: actualTokens)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if !segment.children.isEmpty {
                    Button {
                        if isExpanded { expanded.remove(segment.id) } else { expanded.insert(segment.id) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 11)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Spacer().frame(width: 11)
                }

                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                    .frame(width: 13)

                Text(segment.label)
                    .font(.system(size: 11.5, weight: depth == 0 ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if segment.text != nil {
                    Button {
                        inspecting = segment
                    } label: {
                        Image(systemName: "eye").font(.system(size: 8.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Show the exact text")
                }

                Spacer(minLength: 6)

                Text(Fmt.tokens(tokens))
                    .font(Design.numeric(10.5, weight: .semibold))
                    .frame(width: 54, alignment: .trailing)
                Text(String(format: "%.1f%%", 100 * segment.share(of: payloadCharacters)))
                    .font(Design.numeric(10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.leading, CGFloat(depth) * 14)

            RatioBar(fraction: segment.share(of: payloadCharacters), tint: tint, height: 3)
                .padding(.leading, CGFloat(depth) * 14 + 24)
                .padding(.trailing, 98)

            if isExpanded {
                ForEach(segment.children) { child in
                    SegmentRow(
                        segment: child,
                        depth: depth + 1,
                        payloadCharacters: payloadCharacters,
                        actualTokens: actualTokens,
                        expanded: $expanded,
                        inspecting: $inspecting)
                }
            }
        }
    }

    private var symbol: String {
        switch segment.kind {
        case .systemPrompt: return "text.alignleft"
        case .contextFile: return "doc.text.fill"
        case .skills: return "wand.and.stars"
        case .skill: return "wand.and.rays"
        case .tools: return "wrench.and.screwdriver.fill"
        case .tool: return "wrench"
        case .message: return "bubble.left.fill"
        case .parameters: return "slider.horizontal.3"
        case .other: return "circle"
        }
    }

    private var tint: Color {
        switch segment.kind {
        case .systemPrompt: return Design.assistant
        case .contextFile: return Design.user
        case .skills, .skill: return Design.tool
        case .tools, .tool: return Design.bash
        case .message: return Design.accent
        case .parameters: return .secondary
        case .other: return .secondary
        }
    }
}

// MARK: - Text sheet

struct SegmentTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    var segment: PayloadSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(segment.label).font(.system(size: 13, weight: .semibold))
                    Text("\(segment.characters) characters · ≈\(Fmt.tokens(segment.estimatedTokens)) tokens")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(segment.text ?? "")
                    .font(Design.mono(11.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 760, height: 620)
    }
}

extension PayloadSegment: @retroactive Identifiable {}

// MARK: - Raw payload

struct RawPayloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    var records: [WireRecord]
    @State private var selected: Int = 0

    private var requests: [WireRecord] { records.filter { $0.kind == .request } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Recorded requests").font(.system(size: 13, weight: .semibold))
                if requests.count > 1 {
                    Picker("", selection: $selected) {
                        ForEach(Array(requests.enumerated()), id: \.offset) { i, r in
                            Text("#\(r.seq) · \(Fmt.clock(r.at))").tag(i)
                        }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 220)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if requests.indices.contains(selected), let payload = requests[selected].payload {
                ScrollView {
                    Text(payload.prettyPrinted)
                        .font(Design.mono(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                EmptyStateView(
                    symbol: "tray",
                    title: "Nothing recorded",
                    message: "Start a run with “Record what's sent to the model” enabled.")
            }
        }
        .frame(width: 860, height: 680)
    }
}
