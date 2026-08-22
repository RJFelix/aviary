import AviaryCore
import SwiftUI

/// The reachable catalogue, in your order, with the ones you don't want switched off.
///
/// Two things are being expressed here and they are deliberately separate. Order is what a
/// picker offers first — the models you actually reach for. Disabling is narrower: it hides a
/// model from pickers without claiming it is gone, so a session that already uses it still
/// resumes and still reads back. That is why the count says "offered", not "available".
struct ModelOrderCard: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var rows: [ModelSpec] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.modelCatalog.models }
        return model.modelCatalog.models.filter {
            $0.qualifiedID.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }

    /// Dragging is only coherent over the whole list: moving row 2 above row 5 of a *filtered*
    /// view says nothing about where they belong among the models the filter hid.
    private var canReorder: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Card("Your catalogue", symbol: "line.3.horizontal.decrease") {
            VStack(alignment: .leading, spacing: 8) {
                header

                if model.modelCatalog.models.isEmpty {
                    Text("No provider has working credentials, so there is nothing to order.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(rows) { spec in
                            ModelOrderRow(spec: spec)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                        }
                        .onMove { offsets, destination in
                            guard canReorder else { return }
                            var next = model.modelCatalog.models
                            next.move(fromOffsets: offsets, toOffset: destination)
                            model.setModelOrder(next)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // A fixed height because this sits inside the page's own ScrollView: a
                    // List that sizes to its content would fight the parent for the scroll.
                    .frame(height: min(460, CGFloat(max(rows.count, 1)) * 30 + 8))
                    .environment(\.defaultMinListRowHeight, 26)
                }

                Text(canReorder
                    ? "Drag to reorder. The order here is the order pickers offer, and the "
                        + "first enabled model is the default for a new run."
                    : "Clear the filter to reorder — dragging inside a filtered list cannot say "
                        + "where a model belongs among the ones being hidden.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain).font(.system(size: 11))
            Spacer()
            Text("\(model.modelCatalog.enabled.count) of \(model.modelCatalog.models.count) offered")
                .font(Design.numeric(10)).foregroundStyle(.tertiary)
            if !model.modelPreferences.order.isEmpty || model.modelCatalog.disabledCount > 0 {
                Button("Reset") { model.resetModelPreferences() }
                    .buttonStyle(.link).font(.system(size: 10))
                    .help("Forget the ordering and offer every reachable model again.")
            }
        }
    }
}

private struct ModelOrderRow: View {
    @Environment(AppModel.self) private var model
    var spec: ModelSpec

    private var isEnabled: Bool { model.modelPreferences.isEnabled(spec) }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { model.setModelEnabled($0, for: spec) }))
                .toggleStyle(.checkbox).labelsHidden()
                .help(isEnabled ? "Offered in pickers" : "Hidden from pickers")

            Text(spec.displayName)
                .font(Design.mono(11))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .lineLimit(1)
            Text(spec.providerID)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Design.accentSoft))
            if spec.isBuiltIn {
                Text("built-in").font(.system(size: 8.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if spec.reasoning {
                Image(systemName: "brain").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("Reasoning model")
            }
            if let ctx = spec.contextWindow {
                Text(Fmt.tokens(ctx)).font(Design.numeric(10)).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9)).foregroundStyle(.quaternary)
        }
        .opacity(isEnabled ? 1 : 0.55)
        .contextMenu {
            Button(isEnabled ? "Stop offering this model" : "Offer this model") {
                model.setModelEnabled(!isEnabled, for: spec)
            }
            Button("Move to top") {
                var next = model.modelCatalog.models.filter { $0.qualifiedID != spec.qualifiedID }
                next.insert(spec, at: 0)
                model.setModelOrder(next)
            }
            Divider()
            Button("Copy \(spec.qualifiedID)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(spec.qualifiedID, forType: .string)
            }
        }
    }
}
