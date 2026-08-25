import SwiftUI
import AppKit
import AviaryCore

/// The improvement board: what you have asked Aviary to become, and what the agent did.
///
/// Laid out as a flat `HStack` with a fixed detail column rather than nested split views.
/// That is not a style preference — an `.inspector()` on an `HSplitView` places the
/// inspector outside the split, and three panes with 300+420+260pt minimums silently clip
/// the leftmost when the window is narrower than their sum. This screen learned that from
/// the Sessions screen.
struct WorkshopView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Pinned to exactly the space the pane offers.
        //
        // Without this the screen could resolve *taller than its own pane* — measured at
        // 3167pt inside a 963pt window, and oscillating — because a greedy child inside a
        // greedy frame can report back more height than it was offered. An over-tall detail
        // pane does not merely clip: `NavigationSplitView` re-solves the whole window for
        // it, and the visible casualty was the sidebar, which went blank on this tab and
        // only this tab. A `GeometryReader` proposes the real size and cannot feed back.
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .sheet(isPresented: Binding(
            get: { model.workshopEditor != nil },
            set: { if !$0 { model.closeWorkshopEditor() } }))
        {
            switch model.workshopEditor {
            case .new:
                WorkshopRequestEditor()
            case .edit(let id):
                if let request = model.board.requests.first(where: { $0.id == id }) {
                    WorkshopRequestEditor(request: request)
                }
            case nil:
                EmptyView()
            }
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                banner
                header
                Divider()
                if model.board.requests.isEmpty {
                    empty
                } else {
                    boardColumns
                }
            }
            // `alignment: .top` is the whole fix for a bug that looked like a missing
            // header. A bare `.frame(maxHeight: .infinity)` *centers* its content, and the
            // empty state inside asks for infinite height — so the stack grew taller than
            // the pane and its top was clipped off the top edge rather than compressed.
            // The header was being drawn above the visible area the entire time, which is
            // why inserting a solid red rectangle to find it also showed nothing.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Gated on the app-wide inspector toggle (⌥⌘I), like every other screen, and
            // given a *flexible* width rather than a fixed one.
            //
            // Both details are load-bearing. A hard 340pt here plus the sidebar's 196pt
            // minimum plus a non-shrinkable control row exceeded the 1100pt minimum window,
            // and NavigationSplitView resolves that overflow by crushing the sidebar to
            // zero width — the column is still there, so it reads as "the tabs vanished"
            // rather than as a layout overflow. Same trap the Sessions screen hit; the fix
            // is to leave nothing in the detail pane that cannot shrink.
            if model.showInspector, model.selectedRequest != nil {
                Divider()
                RequestDetail()
                    .frame(minWidth: 250, idealWidth: 320, maxWidth: 380)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        if model.repoRoot == nil {
            NoticeBanner(
                level: .danger,
                title: "No Aviary checkout found",
                message: "There is nowhere to keep the board, so requests cannot be filed. "
                    + "Aviary looks for the repository containing harness/packages/coding-agent.")
                .padding(Design.gutter)
        } else if model.board.undeliveredCount > 0 {
            NoticeBanner(
                level: .warning,
                title: "\(model.board.undeliveredCount) request\(model.board.undeliveredCount == 1 ? "" : "s") not yet sent",
                message: "They are safe on the board — the log is written before delivery is "
                    + "attempted, so nothing you typed is lost. Send them when an engine is ready.")
                .padding(Design.gutter)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 14) {
                StatTile(
                    label: "open", value: "\(model.board.openCount)",
                    caption: "waiting on the agent",
                    symbol: "tray", tint: Design.accent, emphasis: true)
                Divider().frame(height: 40)
                StatTile(
                    label: "in progress", value: "\(model.board.workingCount)",
                    caption: "claimed or building", symbol: "hammer")
                Divider().frame(height: 40)
                StatTile(
                    label: "done", value: "\(model.board.doneCount)",
                    caption: "shipped into Aviary", symbol: "checkmark.seal")
                Divider().frame(height: 40)
                agentTile
            }
            agentControls
        }
        .padding(Design.gutter)
    }

    private var agentTile: some View {
        let state = model.workshopSessionState
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(state.tint).frame(width: 7, height: 7)
                Text("WORKSHOP AGENT")
                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            Text(state.label)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let id = model.workshopSessionID {
                Text(id)
                    .font(Design.mono(9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("opens on your first request")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            // On the card rather than only in the overflow menu. Which model is doing the
            // self-improvement work is the single most consequential thing about this agent,
            // and it spent weeks on one nobody had chosen precisely because nothing said so.
            Text(model.workshopModelSummary)
                .font(Design.mono(9.5))
                .foregroundStyle(model.chosenWorkshopModel == nil
                    ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Design.accent))
                .lineLimit(1).truncationMode(.middle)
                .help("Set the agent's model from the ••• menu.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Grouped by provider, from the same catalogue every other picker uses, so a model
    /// offered here is one a run can actually start.
    private var workshopModelGroups: [(String, [ModelSpec])] {
        var groups: [(String, [ModelSpec])] = []
        for spec in model.pickerModels {
            if let index = groups.firstIndex(where: { $0.0 == spec.providerID }) {
                groups[index].1.append(spec)
            } else {
                groups.append((spec.providerID, [spec]))
            }
        }
        return groups
    }

    private var agentControls: some View {
        HStack(spacing: 8) {
            Button {
                model.openWorkshopEditor()
            } label: {
                Label(model.isCapturingShot ? "Capturing…" : "New request", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(model.isCapturingShot)
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button {
                model.attachWorkshopSession()
            } label: {
                Label(model.workshopRun == nil ? "Attach agent" : "Show agent",
                      systemImage: "dot.radiowaves.left.and.right")
            }
            .controlSize(.small)
            .disabled(!model.canRunWorkshopAgent || model.repoRoot == nil)

            Spacer(minLength: 0)

            // Secondary actions live in the overflow menu rather than the row. Four labelled
            // buttons gave this row an intrinsic width it could not shrink below, which is
            // half of why the sidebar was being crushed.
            Menu {
                // The agent's model, where the agent is launched from. It used to be
                // unsettable from here and silently took whatever sorted first in models.json,
                // which is how the workshop spent weeks on a model nobody chose.
                Menu("Agent model") {
                    if !model.workshopModelIsSettableHere {
                        Text("The workshop is on the "
                            + "\(model.engineChoice.label) engine, which takes its model from "
                            + "the engine picker in Live.")
                        Divider()
                    }
                    Button {
                        model.chosenWorkshopModel = nil
                    } label: {
                        Label("Follow my default", systemImage:
                            model.chosenWorkshopModel == nil ? "checkmark" : "")
                    }
                    Divider()
                    ForEach(workshopModelGroups, id: \.0) { provider, models in
                        Menu(provider) {
                            ForEach(models) { spec in
                                Button {
                                    model.chosenWorkshopModel = spec.qualifiedID
                                } label: {
                                    Label(spec.displayName, systemImage:
                                        model.chosenWorkshopModel == spec.qualifiedID
                                            ? "checkmark" : "")
                                }
                            }
                        }
                    }
                }
                Text(model.workshopModelSummary)
                Divider()
                Button("Reload board from disk") { model.refreshBoard() }
                if let run = model.workshopRun, !run.hasExited {
                    Button("Open the agent's transcript") {
                        model.focusedRunID = run.id
                        model.section = .live
                    }
                }
                Divider()
                if let root = model.repoRoot {
                    Button("Reveal board file in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [Workshop.logURL(repoRoot: root)])
                    }
                    Button("Reveal agent brief in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [Workshop.briefURL(repoRoot: root)])
                    }
                }
                Divider()
                Button("Forget workshop session") { model.forgetWorkshopSession() }
                    .disabled(model.workshopSessionID == nil)
                Divider()
                Button(model.showInspector ? "Hide request detail" : "Show request detail") {
                    model.showInspector.toggle()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Board

    /// The four columns.
    ///
    /// The height goes on the `ScrollView`, never on the `HStack` inside it. A horizontal
    /// scroller whose content asks for infinite height is an ambiguous layout: it resolves
    /// on screen but never settles offscreen, and a window that never settles paints
    /// nothing at all — every screenshot came back blank apart from the column dividers,
    /// which have an intrinsic size and so drew anyway. The symptom looks like a broken
    /// view and is actually a broken constraint.
    private var boardColumns: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(WorkshopColumn.allCases) { column in
                    BoardColumn(column: column, requests: model.board.column(column))
                        .frame(width: 268)
                    if column != WorkshopColumn.allCases.last { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        EmptyStateView(
            symbol: "hammer",
            title: "Nothing asked for yet",
            message: "Use the button in the bottom-right corner — from any screen — to say "
                + "what Aviary should do differently. Each request is filed to "
                + "workshop/requests.jsonl with a snapshot of what you were looking at, then "
                + "handed to a session that works on Aviary itself.")
    }
}

// MARK: - Column

private struct BoardColumn: View {
    @Environment(AppModel.self) private var model
    let column: WorkshopColumn
    let requests: [WorkshopRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(column.title.uppercased())
                    .font(Design.sectionTitle).tracking(0.6)
                    .foregroundStyle(.secondary)
                Text("\(requests.count)")
                    .font(Design.numeric(9.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            Divider()

            ScrollView {
                // Plain, not lazy: these lists are a handful of cards each, and a lazy
                // container needs a settled viewport to decide what to materialize — which
                // offscreen rendering never provides.
                VStack(spacing: 6) {
                    ForEach(requests) { r in
                        RequestCard(
                            request: r,
                            isSelected: model.selectedRequest?.id == r.id)
                            .onTapGesture { model.selectedRequestID = r.id }
                    }
                    if requests.isEmpty {
                        Text(column == .inbox ? "Nothing waiting" : "—")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 14)
                    }
                }
                .padding(10)
            }
        }
    }
}

private struct RequestCard: View {
    let request: WorkshopRequest
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: request.kind.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text(request.kind.label.uppercased())
                    .font(.system(size: 8.5, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(tint)
                Spacer(minLength: 4)
                if !request.delivered, request.status == .open {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Design.warning)
                        .help("Filed but not yet handed to a session")
                }
                if !request.commits.isEmpty {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Design.success)
                        .help("\(request.commits.count) linked commit(s)")
                }
            }

            Text(request.oneLine)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                if let ctx = request.context, !ctx.section.isEmpty {
                    Chip(text: ctx.section, symbol: "rectangle.on.rectangle", tint: .secondary)
                }
                Spacer(minLength: 0)
                Text(Fmt.relative(request.createdAt))
                    .font(Design.numeric(9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected
                    ? AnyShapeStyle(Design.accentSoft)
                    : AnyShapeStyle(.background.secondary)))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected
                    ? AnyShapeStyle(Design.accent.opacity(0.6))
                    : AnyShapeStyle(.separator.opacity(0.5)),
                    lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch request.kind {
        case .change: return Design.accent
        case .bug: return Design.danger
        case .idea: return Design.assistant
        case .question: return Design.warning
        }
    }
}

// MARK: - Detail

private struct RequestDetail: View {
    @Environment(AppModel.self) private var model
    @State private var noteDraft = ""
    @State private var showShot = false

    var body: some View {
        if let request = model.selectedRequest {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    identity(request)
                    statusControls(request)
                    if !request.body.isEmpty { bodyCard(request) }
                    if let ctx = request.context { contextCard(request, ctx) }
                    if !request.notes.isEmpty { notesCard(request) }
                    if !request.commits.isEmpty || !request.sessions.isEmpty { linksCard(request) }
                    noteComposer(request)
                }
                .padding(Design.gutter)
            }
            .sheet(isPresented: $showShot) {
                if let url = model.screenshotURL(for: request) {
                    ShotSheet(url: url, requestID: request.id)
                }
            }
        }
    }

    private func identity(_ r: WorkshopRequest) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(r.oneLine)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Chip(text: r.kind.label, symbol: r.kind.symbol, tint: Design.accent)
                Chip(text: r.status.label, tint: statusTint(r.status), filled: true)
                if !r.delivered && r.status == .open {
                    Chip(text: "undelivered", symbol: "tray.and.arrow.up", tint: Design.warning)
                }
            }
            Text(r.id)
                .font(Design.mono(10))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Text("Filed \(Fmt.timestamp(r.createdAt))")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Button {
                model.workshopEditor = .edit(r.id)
            } label: {
                Label("Edit request", systemImage: "square.and.pencil")
            }
            .controlSize(.small)
        }
    }

    private func statusControls(_ r: WorkshopRequest) -> some View {
        Card("Your call", symbol: "hand.raised") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if r.status != .done {
                        Button("Mark done") { model.setStatus(.done, for: r) }
                            .controlSize(.small)
                    }
                    if r.status != .parked {
                        Button("Park") { model.setStatus(.parked, for: r) }
                            .controlSize(.small)
                    }
                    if r.status.isTerminal || r.status == .parked {
                        Button("Reopen") { model.setStatus(.open, for: r) }
                            .controlSize(.small)
                    }
                }
                if r.status == .open {
                    Button {
                        model.redeliver(r)
                    } label: {
                        Label(r.delivered ? "Send again" : "Send to agent",
                              systemImage: "paperplane")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isSubmitting || !model.canRunWorkshopAgent)
                }
                Text("Status is a log event, not a field — yours are recorded as “you”, the "
                    + "agent's as “agent”, and both survive in the file.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bodyCard(_ r: WorkshopRequest) -> some View {
        Card("What you wrote", symbol: "text.alignleft") {
            Text(r.body)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func contextCard(_ r: WorkshopRequest, _ ctx: WorkshopContext) -> some View {
        Card("Aviary at that moment", symbol: "camera.viewfinder",
             accessory: AnyView(
                Text("\(ctx.facts.count) facts")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)))
        {
            VStack(alignment: .leading, spacing: 9) {
                if model.screenshotURL(for: r) != nil {
                    Button {
                        showShot = true
                    } label: {
                        Label("View screenshot", systemImage: "photo")
                    }
                    .controlSize(.small)
                }
                ForEach(ctx.groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.uppercased())
                            .font(.system(size: 8.5, weight: .semibold)).tracking(0.5)
                            .foregroundStyle(Design.accent)
                        ForEach(ctx.facts(in: group)) { f in
                            HStack(alignment: .top, spacing: 6) {
                                Text(f.label)
                                    .font(Design.mono(9.5))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 108, alignment: .leading)
                                Text(f.value)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func notesCard(_ r: WorkshopRequest) -> some View {
        Card("History", symbol: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(r.notes) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(n.by.uppercased())
                                .font(.system(size: 8.5, weight: .bold)).tracking(0.4)
                                .foregroundStyle(n.by == "you" ? Design.user : Design.assistant)
                            Text(Fmt.timestamp(n.at))
                                .font(Design.numeric(9))
                                .foregroundStyle(.tertiary)
                        }
                        Text(n.text)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func linksCard(_ r: WorkshopRequest) -> some View {
        Card("Receipts", symbol: "link") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(r.commits, id: \.self) { c in
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 9)).foregroundStyle(Design.success)
                        Text(c).font(Design.mono(10)).textSelection(.enabled)
                    }
                }
                ForEach(r.sessions, id: \.self) { s in
                    Button {
                        model.openTranscript(sessionID: URL(fileURLWithPath: s)
                            .deletingPathExtension().lastPathComponent)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left").font(.system(size: 9))
                            Text(URL(fileURLWithPath: s).lastPathComponent)
                                .font(Design.mono(10)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Design.accent)
                }
            }
        }
    }

    private func noteComposer(_ r: WorkshopRequest) -> some View {
        Card("Add a note", symbol: "square.and.pencil") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("More detail for the agent…", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .lineLimit(1...4)
                HStack {
                    Spacer()
                    Button("Add") {
                        model.addNote(noteDraft, to: r)
                        noteDraft = ""
                    }
                    .controlSize(.small)
                    .disabled(noteDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func statusTint(_ s: WorkshopStatus) -> Color {
        switch s {
        case .open: return Design.accent
        case .claimed, .building: return Design.warning
        case .done: return Design.success
        case .declined: return Design.danger
        case .parked: return .secondary
        }
    }
}

/// The deliberate, roomy place to compose a request or revise the text on an existing one.
/// The small global capture panel remains useful for a quick thought on another screen; this
/// editor belongs to the board and makes both creation and amendment use the same controls.
private struct WorkshopRequestEditor: View {
    @Environment(AppModel.self) private var model
    let request: WorkshopRequest?
    @State private var title: String
    @State private var detail: String
    @State private var kind: WorkshopKind

    init(request: WorkshopRequest? = nil) {
        self.request = request
        _title = State(initialValue: request?.title ?? "")
        _detail = State(initialValue: request?.body ?? "")
        _kind = State(initialValue: request?.kind ?? .change)
    }

    private var isEditing: Bool { request != nil }
    private var hasText: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var bodyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEditing ? "Edit request" : "New request")
                        .font(.system(size: 18, weight: .semibold))
                    Text(isEditing
                         ? "Save an amendment to the append-only board history."
                         : "Describe the change while the captured context is still attached.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.closeWorkshopEditor() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }

            Picker("Kind", selection: $kind) {
                ForEach(WorkshopKind.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 5) {
                Text("TITLE").font(Design.sectionTitle).foregroundStyle(.secondary)
                TextField("One line: what should change?", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("DETAIL").font(Design.sectionTitle).foregroundStyle(.secondary)
                TextEditor(text: $detail)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.background.secondary))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if detail.isEmpty {
                            Text("Add the detail the agent needs: expected behavior, what happened, and any constraints.")
                                .font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 13).padding(.top, 13)
                                .allowsHitTesting(false)
                        }
                    }
            }

            if !isEditing {
                let facts = model.pendingContext?.facts.count ?? 0
                HStack(spacing: 6) {
                    Image(systemName: model.pendingShot == nil ? "camera.badge.ellipsis" : "camera")
                    Text("\(facts) facts captured from the \(model.section.title) tab")
                    if model.pendingShot != nil {
                        Toggle(isOn: Binding(
                            get: { model.draftIncludesShot },
                            set: { model.draftIncludesShot = $0 }))
                        {
                            Text("Screenshot")
                        }
                        .toggleStyle(.checkbox).controlSize(.mini)
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            HStack {
                if isEditing {
                    Text("The original request and its snapshot remain in the log.")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(model.isSubmitting ? "Saving…" : (isEditing ? "Save changes" : "File request")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSubmitting || !hasText)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    var body: some View { bodyView }

    private func save() {
        if let request {
            model.updateRequest(request, title: title, body: detail, kind: kind)
        } else {
            model.submitRequest(title: title, body: detail, kind: kind)
        }
    }
}

private struct ShotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let requestID: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aviary when \(requestID) was filed")
                        .font(.system(size: 13, weight: .semibold))
                    Text(url.path)
                        .font(Design.mono(9.5)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let image = NSImage(contentsOf: url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1180)
                }
            } else {
                EmptyStateView(
                    symbol: "photo",
                    title: "Screenshot missing",
                    message: "The file recorded with this request is no longer at \(url.path).")
            }
        }
        .frame(width: 1200, height: 780)
    }
}
