import Foundation

/// One coherent launcher selection across the direct Aviary route and Claude Code.
///
/// Picker changes are explicit transitions. A missing catalogue route leaves the requested
/// route selected with empty visible provider/model values; it never turns absence into a
/// different engine choice. Remembered values survive that absence and are reconsidered when
/// the catalogue changes.
public struct LauncherSelection: Hashable, Sendable {
    public enum Route: Hashable, Sendable {
        case direct
        case claudeCode
    }

    public static let claudeCodeProviderID = "claude-code"

    public let route: Route
    public let providerID: String
    public let modelID: String

    private let directProviderID: String
    private let directModelID: String
    private let claudeCodeModelID: String

    private init(
        route: Route,
        providerID: String,
        modelID: String,
        directProviderID: String,
        directModelID: String,
        claudeCodeModelID: String
    ) {
        self.route = route
        self.providerID = providerID
        self.modelID = modelID
        self.directProviderID = directProviderID
        self.directModelID = directModelID
        self.claudeCodeModelID = claudeCodeModelID
    }

    public static func seeded(
        route: Route,
        defaultProviderID: String?,
        defaultModelID: String?,
        claudeCodeModelID: String,
        models: [ModelSpec]
    ) -> Self {
        let providers = providerIDs(in: models)
        let directProvider = provider(
            claudeCode: false, preferred: defaultProviderID, fallback: nil,
            providers: providers)
        let directModel = model(
            preferred: directProvider == defaultProviderID ? defaultModelID : nil,
            fallback: nil,
            models: Self.models(for: directProvider, in: models))
        let claudeProvider = provider(
            claudeCode: true, preferred: Self.claudeCodeProviderID, fallback: nil,
            providers: providers)
        let claudeModel = model(
            preferred: claudeCodeModelID, fallback: nil,
            models: Self.models(for: claudeProvider, in: models))

        return Self(
            route: route,
            providerID: route == .claudeCode ? claudeProvider : directProvider,
            modelID: route == .claudeCode ? claudeModel : directModel,
            directProviderID: directProvider.isEmpty
                ? defaultProviderID ?? "" : directProvider,
            directModelID: directModel.isEmpty ? defaultModelID ?? "" : directModel,
            claudeCodeModelID: claudeModel.isEmpty ? claudeCodeModelID : claudeModel)
    }

    public func selectingRoute(
        _ route: Route,
        defaultProviderID: String?,
        defaultModelID: String?,
        fallbackClaudeCodeModelID: String,
        models: [ModelSpec]
    ) -> Self {
        let remembered = self
        let providers = Self.providerIDs(in: models)

        switch route {
        case .claudeCode:
            let provider = Self.provider(
                claudeCode: true, preferred: Self.claudeCodeProviderID, fallback: nil,
                providers: providers)
            let model = Self.model(
                preferred: remembered.claudeCodeModelID,
                fallback: fallbackClaudeCodeModelID,
                models: Self.models(for: provider, in: models))
            return remembered.replacingActive(
                route: route, providerID: provider, modelID: model,
                claudeCodeModelID: model.isEmpty ? remembered.claudeCodeModelID : model)

        case .direct:
            let provider = Self.provider(
                claudeCode: false,
                preferred: remembered.directProviderID,
                fallback: defaultProviderID,
                providers: providers)
            let model = Self.model(
                preferred: provider == remembered.directProviderID
                    ? remembered.directModelID : nil,
                fallback: provider == defaultProviderID ? defaultModelID : nil,
                models: Self.models(for: provider, in: models))
            return remembered.replacingActive(
                route: route, providerID: provider, modelID: model,
                directProviderID: provider.isEmpty
                    ? remembered.directProviderID : provider,
                directModelID: model.isEmpty ? remembered.directModelID : model)
        }
    }

    public func selectingProvider(
        _ requestedProviderID: String,
        defaultProviderID: String?,
        defaultModelID: String?,
        fallbackClaudeCodeModelID: String,
        models: [ModelSpec]
    ) -> Self {
        let remembered = self
        let nextRoute: Route
        if requestedProviderID == Self.claudeCodeProviderID {
            nextRoute = .claudeCode
        } else if requestedProviderID.isEmpty {
            nextRoute = route
        } else {
            nextRoute = .direct
        }

        let providers = Self.providerIDs(in: models)
        let selectedProvider = Self.provider(
            claudeCode: nextRoute == .claudeCode,
            preferred: requestedProviderID,
            fallback: nextRoute == .direct ? defaultProviderID : nil,
            providers: providers)
        let rememberedModel = nextRoute == .claudeCode
            ? remembered.claudeCodeModelID
            : selectedProvider == remembered.directProviderID
                ? remembered.directModelID : nil
        let fallbackModel = nextRoute == .claudeCode
            ? fallbackClaudeCodeModelID
            : selectedProvider == defaultProviderID ? defaultModelID : nil
        let selectedModel = Self.model(
            preferred: rememberedModel, fallback: fallbackModel,
            models: Self.models(for: selectedProvider, in: models))

        if nextRoute == .claudeCode {
            return remembered.replacingActive(
                route: nextRoute, providerID: selectedProvider, modelID: selectedModel,
                claudeCodeModelID: selectedModel.isEmpty
                    ? remembered.claudeCodeModelID : selectedModel)
        }
        return remembered.replacingActive(
            route: nextRoute, providerID: selectedProvider, modelID: selectedModel,
            directProviderID: selectedProvider.isEmpty
                ? remembered.directProviderID : selectedProvider,
            directModelID: selectedModel.isEmpty
                ? remembered.directModelID : selectedModel)
    }

    public func selectingModel(_ requestedModelID: String, models: [ModelSpec]) -> Self {
        let selectedModel = Self.model(
            preferred: requestedModelID,
            fallback: modelID,
            models: Self.models(for: providerID, in: models))
        guard !selectedModel.isEmpty else { return self }
        if route == .claudeCode {
            return replacingActive(
                route: route, providerID: providerID, modelID: selectedModel,
                claudeCodeModelID: selectedModel)
        }
        return replacingActive(
            route: route, providerID: providerID, modelID: selectedModel,
            directProviderID: providerID, directModelID: selectedModel)
    }

    public func reconciling(
        defaultProviderID: String?,
        defaultModelID: String?,
        fallbackClaudeCodeModelID: String,
        models: [ModelSpec]
    ) -> Self {
        let remembered = self
        let providers = Self.providerIDs(in: models)
        let provider = Self.provider(
            claudeCode: route == .claudeCode,
            preferred: route == .claudeCode
                ? Self.claudeCodeProviderID : remembered.directProviderID,
            fallback: route == .direct ? defaultProviderID : nil,
            providers: providers)
        let preferredModel = route == .claudeCode
            ? remembered.claudeCodeModelID
            : provider == remembered.directProviderID ? remembered.directModelID : nil
        let fallbackModel = route == .claudeCode
            ? fallbackClaudeCodeModelID
            : provider == defaultProviderID ? defaultModelID : nil
        let model = Self.model(
            preferred: preferredModel, fallback: fallbackModel,
            models: Self.models(for: provider, in: models))
        // A catalogue refresh can be temporarily incomplete. Update what the pickers can show,
        // but do not replace the user's remembered choices with a transient fallback.
        return remembered.replacingActive(route: route, providerID: provider, modelID: model)
    }

    /// Small resolvers retained as public API for executable probes and other presentation code.
    public static func provider(
        claudeCode: Bool,
        preferred: String?,
        fallback: String?,
        providers: [String]
    ) -> String {
        let compatible = providers.filter {
            claudeCode ? $0 == claudeCodeProviderID : $0 != claudeCodeProviderID
        }
        if let preferred, compatible.contains(preferred) { return preferred }
        if let fallback, compatible.contains(fallback) { return fallback }
        return compatible.first ?? ""
    }

    public static func model(
        preferred: String?,
        fallback: String?,
        models: [ModelSpec]
    ) -> String {
        if let preferred, models.contains(where: { $0.id == preferred }) { return preferred }
        if let fallback, models.contains(where: { $0.id == fallback }) { return fallback }
        return models.first?.id ?? ""
    }

    private func replacingActive(
        route: Route,
        providerID: String,
        modelID: String,
        directProviderID: String? = nil,
        directModelID: String? = nil,
        claudeCodeModelID: String? = nil
    ) -> Self {
        Self(
            route: route,
            providerID: providerID,
            modelID: modelID,
            directProviderID: directProviderID ?? self.directProviderID,
            directModelID: directModelID ?? self.directModelID,
            claudeCodeModelID: claudeCodeModelID ?? self.claudeCodeModelID)
    }

    private static func providerIDs(in models: [ModelSpec]) -> [String] {
        var seen = Set<String>()
        return models.compactMap {
            seen.insert($0.providerID).inserted ? $0.providerID : nil
        }
    }

    private static func models(for providerID: String, in models: [ModelSpec]) -> [ModelSpec] {
        models.filter { $0.providerID == providerID }
    }
}
