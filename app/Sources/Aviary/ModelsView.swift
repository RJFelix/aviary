import SwiftUI
import AppKit
import AviaryCore

/// Providers, models, and whether they will actually work.
///
/// The centrepiece here is credential resolution. The harness resolves a provider's
/// `apiKey` field client-side and accepts three forms — a `!command`, a bare
/// environment-variable name, or a literal. When a named variable is *absent* it does not
/// error: it sends the variable's own name as the credential, and the provider answers 401
/// with a message that reads like a typo in the config. This screen resolves each
/// expression the same way and says out loud which of the three happened.
struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProviderID: String?
    @State private var resolutions: [String: ApiKeyResolution] = [:]
    @State private var modelSearch = ""

    var body: some View {
        HSplitView {
            providerList
                .frame(minWidth: 240, idealWidth: 290, maxWidth: 400)
            detail
                .frame(minWidth: 420)
        }
        .task { await resolveAll() }
        .onChange(of: model.modelsConfig.providers.count) { _, _ in
            Task { await resolveAll() }
        }
    }

    // MARK: Provider list

    private var providerList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("PROVIDERS")
                    .font(Design.sectionTitle).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.reloadModelsConfig()
                    Task { await resolveAll() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.modelsConfig.fileURL])
                } label: {
                    Image(systemName: "folder").font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Reveal models.json")
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)

            Divider()

            List(selection: $selectedProviderID) {
                SwiftUI.Section("Configured in models.json") {
                    ForEach(model.modelsConfig.providers) { p in
                        ProviderRow(
                            provider: p,
                            resolution: resolutions[p.id],
                            test: model.providerTests[p.id],
                            reachableCount: reachableCount(p.id))
                            .tag(p.id)
                    }
                }
                if !builtInProviders.isEmpty {
                    SwiftUI.Section("Built into the engine") {
                        ForEach(builtInProviders, id: \.self) { id in
                            BuiltInProviderRow(
                                id: id,
                                modelCount: reachableCount(id),
                                authKind: model.auth.kinds[id])
                                .tag("builtin:\(id)")
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .background(.background.secondary)
    }

    /// Providers the engine reports but models.json doesn't declare — the OAuth ones.
    private var builtInProviders: [String] {
        let configured = Set(model.modelsConfig.providers.map(\.id))
        return Array(Set(model.runtimeModels.map(\.providerID)).subtracting(configured)).sorted()
    }

    private func reachableCount(_ providerID: String) -> Int {
        model.runtimeModels.filter { $0.providerID == providerID }.count
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedProviderID {
            if id.hasPrefix("builtin:") {
                BuiltInProviderDetail(
                    providerID: String(id.dropFirst("builtin:".count)),
                    search: $modelSearch)
            } else if let p = model.modelsConfig.providers.first(where: { $0.id == id }) {
                ProviderDetail(
                    provider: p,
                    resolution: resolutions[p.id],
                    search: $modelSearch,
                    onResolve: { Task { await resolve(p) } })
            } else {
                EmptyStateView(symbol: "cpu", title: "Gone", message: "That provider is no longer in models.json.")
            }
        } else {
            overview
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    StatTile(
                        label: "reachable models",
                        value: "\(model.runtimeModels.count)",
                        caption: "what the engine says it can call",
                        symbol: "checkmark.circle.fill", tint: Design.success, emphasis: true)
                    Divider().frame(height: 46)
                    StatTile(
                        label: "providers", value: "\(providerCount)",
                        caption: "\(model.modelsConfig.providers.count) configured, "
                            + "\(builtInProviders.count) built in",
                        symbol: "server.rack")
                    Divider().frame(height: 46)
                    StatTile(
                        label: "credential problems", value: "\(problemCount)",
                        caption: problemCount == 0 ? "all keys resolve" : "would 401 as configured",
                        symbol: "key.fill",
                        tint: problemCount == 0 ? Design.success : Design.danger)
                }
                .padding(Design.cardPadding)
                .background(
                    RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                        .fill(.background.secondary))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 1))

                if let err = model.runtimeModelsError {
                    NoticeBanner(
                        level: .warning,
                        title: "Could not ask the engine for its model catalog",
                        message: err)
                }

                Card("Everything reachable", symbol: "list.bullet.rectangle") {
                    ModelTable(models: model.runtimeModels, search: $modelSearch)
                }

                Card("Where this comes from", symbol: "questionmark.circle") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Two different catalogs feed this screen, and they do not agree "
                            + "by design.")
                            .font(.system(size: 11.5))
                        DetailRow(
                            label: "models.json", value: model.modelsConfig.fileURL.path, mono: true)
                        Text("Providers you configured, with base URLs and key expressions. "
                            + "Aviary can edit this file.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().opacity(0.5)
                        DetailRow(label: "engine catalog", value: "get_available_models over RPC")
                        Text("What the engine can actually reach right now, including built-in "
                            + "providers that authenticate by OAuth and never appear in "
                            + "models.json. Context windows here are route-specific: the same "
                            + "weights are often declared with very different limits on a "
                            + "subscription route versus a metered API route.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Design.gutter)
        }
    }

    private var providerCount: Int {
        Set(model.modelsConfig.providers.map(\.id)).union(builtInProviders).count
    }

    private var problemCount: Int {
        resolutions.values.filter { $0.outcome.isProblem }.count
    }

    // MARK: Resolution

    private func resolveAll() async {
        for p in model.modelsConfig.providers { await resolve(p) }
    }

    private func resolve(_ p: ProviderSpec) async {
        resolutions[p.id] = await ApiKeyResolver.resolve(p.apiKeyExpression)
    }
}

// MARK: - Rows

struct ProviderRow: View {
    var provider: ProviderSpec
    var resolution: ApiKeyResolution?
    var test: ProviderTestResult?
    var reachableCount: Int

    var body: some View {
        HStack(spacing: 7) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(provider.models.count) declared")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    if reachableCount != provider.models.count {
                        Text("· \(reachableCount) reachable")
                            .font(.system(size: 9.5))
                            .foregroundStyle(reachableCount == 0 ? Design.warning : Color.secondary.opacity(0.7))
                    }
                }
            }
            Spacer(minLength: 4)
            if let form = provider.keyForm {
                Image(systemName: formSymbol(form))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(form.label)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let test {
            Image(systemName: test.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(test.ok ? Design.success : Design.danger)
        } else if let resolution, resolution.outcome.isProblem {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Design.warning)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
    }

    private func formSymbol(_ form: ApiKeyForm) -> String {
        switch form {
        case .command: return "terminal"
        case .environmentVariable: return "dollarsign"
        case .literal: return "text.quote"
        }
    }
}

struct BuiltInProviderRow: View {
    var id: String
    var modelCount: Int
    var authKind: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: authKind != nil ? "checkmark.seal.fill" : "seal")
                .font(.system(size: 11))
                .foregroundStyle(authKind != nil ? Design.success : Color.secondary.opacity(0.35))
            VStack(alignment: .leading, spacing: 1) {
                Text(id).font(.system(size: 12, weight: .medium))
                Text(authKind.map { "\($0) · \(modelCount) models" } ?? "\(modelCount) models")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Provider detail

struct ProviderDetail: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderSpec
    var resolution: ApiKeyResolution?
    @Binding var search: String
    var onResolve: () -> Void

    @State private var testModelID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                credentialCard
                if let test = model.providerTests[provider.id] { testResultCard(test) }
                Card("Models", symbol: "list.bullet") {
                    ModelTable(
                        models: provider.models,
                        search: $search,
                        reachable: Set(model.runtimeModels
                            .filter { $0.providerID == provider.id }.map(\.id)))
                }
                configCard
            }
            .padding(Design.gutter)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.system(size: 17, weight: .semibold))
                Chip(text: provider.id, tint: .secondary)
                if provider.hasStoredAuth {
                    Chip(text: provider.authKind ?? "authenticated",
                         symbol: "checkmark.seal", tint: Design.success)
                }
                Spacer()
            }
            HStack(spacing: 7) {
                Button {
                    let m = provider.models.first { $0.id == testModelID } ?? provider.models.first
                    Task { await model.testProvider(provider, model: m) }
                } label: {
                    if model.testingProviders.contains(provider.id) {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Label("Send a test completion", systemImage: "bolt.horizontal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.testingProviders.contains(provider.id) || provider.models.isEmpty)

                if provider.models.count > 1 {
                    Picker("", selection: Binding(
                        get: { testModelID ?? provider.models.first?.id ?? "" },
                        set: { testModelID = $0 }))
                    {
                        ForEach(provider.models) { m in Text(m.id).tag(m.id) }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 220)
                }

                Button("Re-resolve key") { onResolve() }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }
        }
    }

    private var credentialCard: some View {
        Card("Credential", symbol: "key.fill") {
            VStack(alignment: .leading, spacing: 8) {
                if let expr = provider.apiKeyExpression {
                    DetailRow(label: "Expression", value: expr, mono: true)
                    if let form = provider.keyForm {
                        DetailRow(label: "Interpreted as", value: form.label)
                    }
                } else {
                    Text("No apiKey field.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }

                if let r = resolution {
                    Divider().opacity(0.5)
                    HStack(spacing: 7) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(r.ok ? Design.success : Design.warning)
                        Text(outcomeTitle(r))
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if let masked = r.masked {
                            Text("\(masked) · \(r.length) chars")
                                .font(Design.mono(10)).foregroundStyle(.tertiary)
                        }
                    }
                    Text(r.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if case .fellBackToLiteralName(let name) = r.outcome {
                        HStack(spacing: 7) {
                            Button("Copy the launcher-independent form") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    "!zsh -ic 'printf %s \"$\(name)\"'", forType: .string)
                                model.show("Copied — paste it as this provider's apiKey")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                        }
                    }
                }

                if !ProcessEnvironment.shared.isLoginShellEnvironment {
                    Divider().opacity(0.5)
                    Text("Aviary is using the process environment rather than your login "
                        + "shell's, so this resolution may differ from what a terminal sees.")
                        .font(.system(size: 10)).foregroundStyle(Design.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func outcomeTitle(_ r: ApiKeyResolution) -> String {
        switch r.outcome {
        case .resolved: return "Resolves"
        case .fellBackToLiteralName: return "Will send the variable name as the key"
        case .commandFailed: return "The command failed"
        case .empty: return "Resolved to nothing"
        case .noKeyConfigured: return "No credential configured"
        }
    }

    private func testResultCard(_ test: ProviderTestResult) -> some View {
        Card("Last test", symbol: test.ok ? "checkmark.seal.fill" : "xmark.octagon.fill") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Chip(text: test.ok ? "OK" : "FAILED",
                         tint: test.ok ? Design.success : Design.danger, filled: true)
                    if let s = test.httpStatus { Chip(text: "HTTP \(s)", tint: .secondary) }
                    Chip(text: Fmt.duration(test.latency), symbol: "clock", tint: .secondary)
                    if let m = test.modelID { Chip(text: m, tint: Design.assistant) }
                    Spacer()
                    Text(Fmt.ago(test.testedAt))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Text(test.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(test.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Design.danger))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let completion = test.completion {
                    Divider().opacity(0.5)
                    Text("MODEL SAID")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(completion)
                        .font(Design.mono(11))
                        .textSelection(.enabled)
                }
                Text("A completed round trip is not proof the route can back an agent: the "
                    + "harness needs a route that emits real tool calls, and a route that "
                    + "flattens the message array will answer prose here and never call a tool.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configCard: some View {
        Card("Configuration", symbol: "doc.text") {
            VStack(alignment: .leading, spacing: 5) {
                DetailRow(label: "Base URL", value: provider.baseURL ?? "—", mono: true)
                DetailRow(label: "API", value: provider.api ?? "—", mono: true)
                if let h = provider.authHeader {
                    DetailRow(label: "Auth header", value: h, mono: true)
                }
                if !provider.headers.isEmpty {
                    DetailRow(
                        label: "Extra headers",
                        value: provider.headers.keys.sorted().joined(separator: ", "), mono: true)
                }
                Divider().opacity(0.5)
                Button("Edit models.json") {
                    NSWorkspace.shared.open(model.modelsConfig.fileURL)
                }
                .buttonStyle(.link).font(.system(size: 10.5))
            }
        }
    }
}

struct BuiltInProviderDetail: View {
    @Environment(AppModel.self) private var model
    var providerID: String
    @Binding var search: String

    private var models: [ModelSpec] {
        model.runtimeModels.filter { $0.providerID == providerID }.sorted { $0.id < $1.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(providerID).font(.system(size: 17, weight: .semibold))
                    Chip(text: "built in", tint: Design.accent)
                    if let kind = model.auth.kinds[providerID] {
                        Chip(text: kind, symbol: "checkmark.seal", tint: Design.success)
                    }
                    Spacer()
                }

                Card("How this authenticates", symbol: "key.fill") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let kind = model.auth.kinds[providerID] {
                            Text("Credentials are stored in auth.json as `\(kind)`. Aviary reads "
                                + "only the provider names and auth kinds from that file — never "
                                + "the tokens.")
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                            if kind == "oauth" {
                                Text("An OAuth route draws on a subscription, so its per-token "
                                    + "cost is quota rather than dollars, and a local gateway "
                                    + "cannot proxy it.")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("No stored credentials for this provider. Run the engine's "
                                + "`auth` command to sign in.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        DetailRow(
                            label: "auth.json",
                            value: model.auth.permissionsAreTight
                                ? "owner-only permissions" : "readable by others",
                            tint: model.auth.permissionsAreTight ? nil : Design.danger)
                    }
                }

                Card("Models", symbol: "list.bullet") {
                    ModelTable(models: models, search: $search)
                }
            }
            .padding(Design.gutter)
        }
    }
}

// MARK: - Model table

struct ModelTable: View {
    var models: [ModelSpec]
    @Binding var search: String
    var reachable: Set<String>?

    private var rows: [ModelSpec] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty
            ? models
            : models.filter {
                $0.id.lowercased().contains(q)
                    || $0.displayName.lowercased().contains(q)
                    || $0.providerID.lowercased().contains(q)
            }
        return filtered.sorted { ($0.providerID, $0.id) < ($1.providerID, $1.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("Filter models", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 11))
                Spacer()
                Text("\(rows.count)").font(Design.numeric(10)).foregroundStyle(.tertiary)
            }

            if rows.isEmpty {
                Text("No models match.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ForEach(rows) { m in
                        ModelRow(model: m, isReachable: reachable?.contains(m.id))
                        if m.id != rows.last?.id { Divider().opacity(0.35) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("MODEL").frame(maxWidth: .infinity, alignment: .leading)
            Text("CTX").frame(width: 58, alignment: .trailing)
            Text("MAX OUT").frame(width: 58, alignment: .trailing)
            Text("IN $/M").frame(width: 52, alignment: .trailing)
            Text("OUT $/M").frame(width: 52, alignment: .trailing)
            Text("").frame(width: 66)
        }
        .font(.system(size: 8.5, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(.tertiary)
    }
}

struct ModelRow: View {
    var model: ModelSpec
    var isReachable: Bool?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(model.id)
                    .font(Design.mono(9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(model.contextWindow.map(Fmt.tokens) ?? "—")
                .frame(width: 58, alignment: .trailing)
            Text(model.maxTokens.map(Fmt.tokens) ?? "—")
                .frame(width: 58, alignment: .trailing)
            Text(model.costInput.map { fmtMoney($0) } ?? "—")
                .frame(width: 52, alignment: .trailing)
            Text(model.costOutput.map { fmtMoney($0) } ?? "—")
                .frame(width: 52, alignment: .trailing)

            HStack(spacing: 3) {
                if model.reasoning {
                    Image(systemName: "brain").foregroundStyle(Design.thinking)
                        .help("Reasoning model")
                }
                if model.supportsImages {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                        .help("Accepts images")
                }
                if !model.deadThinkingLevels.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Design.warning)
                        .help("Thinking levels that map to nothing on this route: "
                            + model.deadThinkingLevels.joined(separator: ", "))
                }
                if isReachable == false {
                    Image(systemName: "eye.slash").foregroundStyle(Design.warning)
                        .help("Declared in models.json but the engine did not report it as "
                            + "reachable")
                }
            }
            .font(.system(size: 9))
            .frame(width: 66, alignment: .trailing)
        }
        .font(Design.numeric(10.5))
        .padding(.vertical, 4)
    }

    private func fmtMoney(_ d: Double) -> String {
        if d == 0 { return "0" }
        if d == d.rounded() { return String(Int(d)) }
        return String(format: "%.2f", d)
    }
}
