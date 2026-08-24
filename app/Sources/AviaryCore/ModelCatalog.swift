import Foundation

/// How you want models presented: what order, and which ones to stop offering.
///
/// Stored in Aviary's own Application Support directory rather than in `models.json`. That file
/// is the harness's, hand-maintained, and holds facts about providers; "I don't want to see this
/// in a picker" is a fact about *you*. Writing a cosmetic preference into a file another tool
/// owns would also mean rewriting it on every reorder.
public struct ModelPreferences: Sendable, Codable, Equatable {
    /// Qualified ids (`provider/model`) in the order they should appear. Anything not listed
    /// comes after, in catalogue order.
    public var order: [String] = []
    /// Qualified ids excluded from pickers.
    public var disabled: Set<String> = []

    public init(order: [String] = [], disabled: Set<String> = []) {
        self.order = order
        self.disabled = disabled
    }

    /// Qualified, because a bare model id is not unique: the same `deepseek-v4-pro` can be
    /// reachable both directly and through a gateway, and they are different routes with
    /// different prices.
    public func isEnabled(_ model: ModelSpec) -> Bool { !disabled.contains(model.qualifiedID) }

    /// Where a model sorts. Unlisted models sort last but keep their catalogue order, so a
    /// model that appears in `models.json` tomorrow neither jumps to the top nor vanishes.
    public func rank(_ model: ModelSpec) -> Int {
        order.firstIndex(of: model.qualifiedID) ?? Int.max
    }

    public mutating func setEnabled(_ enabled: Bool, for model: ModelSpec) {
        if enabled { disabled.remove(model.qualifiedID) } else { disabled.insert(model.qualifiedID) }
    }

    /// Record an explicit order for a list of models.
    ///
    /// Only the given models are re-pinned; ids already in `order` that are not in this list
    /// keep their relative position ahead of the rest. Reordering one provider's models
    /// therefore does not scramble another's.
    public mutating func pin(_ models: [ModelSpec]) {
        let ids = models.map(\.qualifiedID)
        let touched = Set(ids)
        var next = order.filter { !touched.contains($0) }
        // Inserted at the position of the first one that was already ranked, so a reorder
        // inside a group leaves the group where it was in the overall list.
        let anchor = order.firstIndex { touched.contains($0) } ?? next.count
        next.insert(contentsOf: ids, at: min(anchor, next.count))
        order = next
    }
}

public struct ModelPreferencesStore: Sendable {
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return support.appending(path: "Aviary", directoryHint: .isDirectory)
        }()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "model-preferences.json")
    }

    public func load() -> ModelPreferences {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let decoded = try? JSONDecoder().decode(ModelPreferences.self, from: data)
        else { return ModelPreferences() }
        return decoded
    }

    public func save(_ preferences: ModelPreferences) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(preferences) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Which models are actually reachable, in the order they should be offered.
public struct ModelCatalog: Sendable {
    /// Providers whose credentials resolve, models already in preference order.
    public var reachable: [ProviderSpec] = []
    /// Configured but with no usable credential. Kept rather than dropped: "you configured this
    /// and it is not working" is the more useful thing to say than showing nothing.
    public var unreachable: [ProviderSpec] = []
    /// Every reachable model in preference order, including disabled ones.
    public var models: [ModelSpec] = []
    /// What a picker should offer.
    public var enabled: [ModelSpec] = []

    public init() {}

    public var disabledCount: Int { models.count - enabled.count }

    /// Find a model by qualified or bare id, **ignoring whether it is enabled**.
    ///
    /// Disabling hides a model from pickers; it must not break resuming a session that already
    /// uses it, or reading one back. A preference about what to offer is not a claim that the
    /// model is gone.
    public func find(_ reference: String) -> ModelSpec? {
        if reference.contains("/"), let hit = models.first(where: { $0.qualifiedID == reference }) {
            return hit
        }
        return models.first { $0.id == reference }
    }
}

public enum ModelCatalogBuilder {
    /// Build the catalogue.
    ///
    /// Pure, so the ordering and enabling rules are testable without credentials or a network:
    /// which providers have working credentials is decided by the caller and passed in.
    public static func build(
        config: ModelsConfig,
        auth: AuthInfo?,
        credentialed: Set<String>,
        preferences: ModelPreferences
    ) -> ModelCatalog {
        var out = ModelCatalog()

        // Built-ins last, matching `AgentCLI.resolve`: a models.json entry always wins, because
        // configuring a provider explicitly means you meant it.
        var candidates = config.providers
        let codex = BuiltInProviders.openAICodex(auth: auth)
        if !candidates.contains(where: { $0.id == codex.id }) { candidates.append(codex) }
        // Claude Code is a provider here even though it is not an HTTP route, because "which
        // model is answering" is the same question for it as for anything else. Its
        // reachability is decided by the caller — it depends on `claude auth status`, not on a
        // key expression — and arrives through `credentialed` like a configured provider's.
        let claudeCode = BuiltInProviders.claudeCode(
            signedIn: credentialed.contains("claude-code"))
        if !candidates.contains(where: { $0.id == claudeCode.id }) {
            candidates.append(claudeCode)
        }

        for provider in candidates {
            // A built-in is reachable when its OAuth credentials are stored; a configured one
            // when its `apiKey` expression resolved. This is the same notion of "reachable" the
            // harness's `get_available_models` uses — models backed by active credentials.
            // A built-in is reachable when its stored credentials are there. Codex reads that
            // from `auth.json`; Claude Code's credential lives in the `claude` binary's own
            // keychain entry, which Aviary cannot and should not read — so the caller resolves
            // it and passes it in.
            let usable = provider.id == "claude-code"
                ? credentialed.contains("claude-code")
                : provider.isBuiltIn
                    ? (auth?.providers.contains(provider.id) ?? false)
                    : credentialed.contains(provider.id)
            if usable {
                out.reachable.append(provider)
            } else {
                out.unreachable.append(provider)
            }
        }

        // Catalogue order first, then a *stable* sort by rank, so unlisted models keep the
        // order they came in rather than being shuffled by an unstable comparison.
        let inCatalogueOrder = out.reachable.flatMap(\.models)
        out.models = inCatalogueOrder
            .enumerated()
            .sorted { a, b in
                let ra = preferences.rank(a.element), rb = preferences.rank(b.element)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
        out.enabled = out.models.filter(preferences.isEnabled)

        // Each provider's own list is ordered the same way, so a per-provider picker and the
        // flat list cannot disagree.
        let position = Dictionary(
            uniqueKeysWithValues: out.models.enumerated().map { ($1.qualifiedID, $0) })
        for i in out.reachable.indices {
            out.reachable[i].models.sort {
                (position[$0.qualifiedID] ?? .max) < (position[$1.qualifiedID] ?? .max)
            }
        }
        return out
    }

    /// Which providers have credentials that actually resolve.
    ///
    /// Resolving means running the `!command` form or reading the environment variable, which is
    /// why this is async and separate from `build`. A provider with stored OAuth counts even
    /// without an `apiKey` expression.
    public static func credentialedProviders(
        config: ModelsConfig, auth: AuthInfo?
    ) async -> Set<String> {
        var out: Set<String> = []
        for provider in config.providers {
            if auth?.providers.contains(provider.id) == true {
                out.insert(provider.id)
                continue
            }
            if let secret = await resolveSecret(provider.apiKeyExpression), !secret.isEmpty {
                out.insert(provider.id)
            }
        }
        return out
    }

    /// The same resolution the harness does. Kept here rather than in the app target so the
    /// catalogue does not depend on the UI layer.
    public static func resolveSecret(_ expression: String?) async -> String? {
        guard let expression, !expression.isEmpty else { return nil }
        switch ApiKeyForm.classify(expression) {
        case .command(let cmd):
            let shell = ProcessEnvironment.shared.value("SHELL") ?? "/bin/zsh"
            guard case .success(let r) = await Shell.run(shell, ["-c", cmd], timeout: 20), r.ok
            else { return nil }
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        case .environmentVariable(let name):
            return ProcessEnvironment.shared.value(name)
        case .literal:
            return expression
        }
    }
}
