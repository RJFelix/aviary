import SwiftUI
import AviaryCore

/// Picking a model, as a panel rather than a submenu.
///
/// This exists because nested `Menu`s do not work inside a `.menuStyle(.borderlessButton)`
/// menu on macOS. The submenu opens, closes itself within about half a second, and drops the
/// highlight on the row that opened it — reproducibly, on an idle run, with static content.
/// Two attempts to fix that by reducing view invalidation failed, because invalidation was
/// never the cause: the same thing happened to a submenu whose entire contents were seven
/// literal strings.
///
/// So the nesting is gone rather than tuned. A panel also gives the list room to be searchable
/// and grouped, which a menu of thirty-four models never had.
struct ModelChooserSheet: View {
    var title: String
    /// Shown above the list when the choice cannot take effect, instead of letting someone
    /// pick and discover afterwards that it did nothing.
    var note: String?
    var models: [ModelSpec]
    /// The model currently in effect, checkmarked.
    var current: String?
    /// Offered as "use whatever the default is" when the caller has a meaningful unset state.
    var clearTitle: String?
    var onClear: (() -> Void)?
    var onPick: (ModelSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var groups: [(String, [ModelSpec])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [(String, [ModelSpec])] = []
        for spec in models {
            guard query.isEmpty
                || spec.id.lowercased().contains(query)
                || spec.providerID.lowercased().contains(query)
            else { continue }
            if let index = out.firstIndex(where: { $0.0 == spec.providerID }) {
                out[index].1.append(spec)
            } else {
                out.append((spec.providerID, [spec]))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Filter models", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
            .padding(.horizontal, 12)

            Divider().padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let clearTitle, let onClear {
                        row(label: clearTitle, detail: nil, checked: current == nil) {
                            onClear()
                            dismiss()
                        }
                        Divider().padding(.leading, 12)
                    }
                    ForEach(groups, id: \.0) { provider, specs in
                        Text(provider.uppercased())
                            .font(Design.sectionTitle).tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
                        ForEach(specs) { spec in
                            row(label: spec.displayName,
                                detail: spec.qualifiedID,
                                checked: current == spec.qualifiedID)
                            {
                                onPick(spec)
                                dismiss()
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text("No model matches.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
        }
        .frame(width: 420, height: 480)
    }

    private func row(
        label: String, detail: String?, checked: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(checked
                        ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 12, weight: checked ? .semibold : .regular))
                    if let detail, detail != label {
                        Text(detail).font(Design.mono(9.5)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Model and thinking level for one run, in a panel that both engines can honour.
struct RunSettingsSheet: View {
    @Environment(AppModel.self) private var model
    var run: LiveRun
    var models: [ModelSpec]

    var body: some View {
        ModelChooserSheet(
            title: "Model for this run",
            note: run.isClaudeCode
                ? "Claude Code owns the loop for this run and takes its model at launch, so "
                    + "changing it here will not take effect. Start a new run instead."
                : nil,
            models: models,
            current: run.modelLabel,
            clearTitle: nil,
            onClear: nil,
            onPick: { spec in
                Task {
                    await model.switchModel(
                        run: run, provider: spec.providerID, model: spec.id)
                }
            })
    }
}
