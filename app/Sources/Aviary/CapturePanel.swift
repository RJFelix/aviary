import SwiftUI
import AviaryCore

/// The bottom-right capture composer, opened from reserved toolbar or menu space.
///
/// It lives in `RootView`'s overlay rather than on any one screen, because the whole point is
/// to catch a reaction where you have it. The collapsed action does not live here: permanent
/// overlay chrome covered primary chat actions, so the toolbar owns the idle affordance.
struct CapturePanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focus: Field?
    @State private var showContext = false

    private enum Field { case title, body }

    var body: some View {
        composer
        .padding(.trailing, 18)
        .padding(.bottom, 18)
        .onAppear { focus = .title }
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
                model.discardPendingCapture()
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
        // The held snapshot, not a fresh reading — so the preview is exactly what will be
        // filed rather than something that merely resembles it.
        let ctx = model.pendingContext ?? model.captureContext()
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
                if model.pendingShot != nil {
                    Toggle(isOn: Binding(
                        get: { model.draftIncludesShot }, set: { model.draftIncludesShot = $0 }))
                    {
                        Text("Screenshot").font(.system(size: 10.5))
                    }
                    .toggleStyle(.checkbox).controlSize(.mini)
                } else {
                    // No image was captured — say so rather than offering a checkbox that
                    // silently attaches nothing.
                    Label("No screenshot", systemImage: "photo.badge.exclamationmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("The window could not be captured. The request will still be filed.")
                }
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
                model.discardPendingCapture()
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
