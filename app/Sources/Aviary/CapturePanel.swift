import SwiftUI
import AviaryCore

/// The bottom-right capture affordance: a pill that opens into a compose card.
///
/// It lives in `RootView`'s overlay rather than on any one screen, because the whole point
/// is to catch a reaction where you have it. A request you had to navigate to a tab to file
/// is a request you file later, differently, or not at all — and the context that made it
/// worth filing is gone by the time you get there.
struct CapturePanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focus: Field?
    @State private var showContext = false

    private enum Field { case title, body }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if model.capturePanelOpen {
                composer
            } else {
                pill
            }
        }
        .padding(.trailing, 18)
        .padding(.bottom, 18)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.capturePanelOpen)
    }

    // MARK: Collapsed

    private var pill: some View {
        Button {
            model.capturePanelOpen = true
            focus = .title
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill").font(.system(size: 10, weight: .semibold))
                Text("Improve Aviary").font(.system(size: 11.5, weight: .medium))
                if model.board.openCount > 0 {
                    Text("\(model.board.openCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Design.accent.opacity(0.22)))
                        .foregroundStyle(Design.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .help("File a change request against Aviary (⇧⌘I)")
    }

    // MARK: Expanded

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            Picker("", selection: Binding(
                get: { model.draftKind }, set: { model.draftKind = $0 }))
            {
                ForEach(WorkshopKind.allCases, id: \.self) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.segmented).labelsHidden()

            TextField("One line: what should change?", text: Binding(
                get: { model.draftTitle }, set: { model.draftTitle = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($focus, equals: .title)
                .onSubmit { focus = .body }

            TextEditor(text: Binding(
                get: { model.draftBody }, set: { model.draftBody = $0 }))
                .font(.system(size: 12))
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if model.draftBody.isEmpty {
                        Text("Detail, if it helps. What you expected, what happened.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.top, 11)
                            .allowsHitTesting(false)
                    }
                }
                .focused($focus, equals: .body)

            contextRow
            footer
        }
        .padding(13)
        .frame(width: 372)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 5)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Design.accent)
            Text("IMPROVE AVIARY")
                .font(Design.sectionTitle).tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button {
                model.capturePanelOpen = false
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
            .keyboardShortcut(.cancelAction)
        }
    }

    /// The captured state, previewed before it is sent. Shown because a snapshot you cannot
    /// inspect is a snapshot you cannot trust — and this one goes into a git-tracked file.
    private var contextRow: some View {
        let ctx = model.captureContext()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    showContext.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showContext ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(ctx.facts.count) facts about the \(model.section.title) tab")
                            .font(.system(size: 10.5))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Toggle(isOn: Binding(
                    get: { model.draftIncludesShot }, set: { model.draftIncludesShot = $0 }))
                {
                    Text("Screenshot").font(.system(size: 10.5))
                }
                .toggleStyle(.checkbox).controlSize(.mini)
            }

            if showContext {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(ctx.facts) { f in
                            HStack(alignment: .top, spacing: 6) {
                                Text(f.label)
                                    .font(Design.mono(9.5))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 116, alignment: .leading)
                                Text(f.value)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(height: 108)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            let state = model.workshopSessionState
            Circle().fill(state.tint).frame(width: 6, height: 6)
            Text(state.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button("Board") {
                model.section = .workshop
                model.capturePanelOpen = false
            }
            .controlSize(.small)
            Button(model.isSubmitting ? "Filing…" : "File it") {
                model.submitRequest()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isSubmitting
                || (model.draftTitle.trimmingCharacters(in: .whitespaces).isEmpty
                    && model.draftBody.trimmingCharacters(in: .whitespaces).isEmpty))
        }
    }
}
