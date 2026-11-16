import Foundation

/// A missing catalogue never changes the requested engine. Each route remembers its own
/// selection, independently of the temporary values a picker can display.
public struct LauncherSelection: Hashable, Sendable {
    public enum Route: Hashable, Sendable { case direct, claudeCode, museCode }
    public static let claudeCodeProviderID = "claude-code"
    public static let museCodeProviderID = "muse-code"
    public private(set) var route: Route
    public private(set) var providerID: String
    public private(set) var modelID: String
    private var directProviderID: String
    private var rememberedModels: [Route: String]

    public static func seeded(
        route: Route, defaultProviderID: String?, defaultModelID: String?,
        claudeCodeModelID: String, museCodeModelID: String = "muse-spark-1.2",
        models: [ModelSpec]
    ) -> Self {
        Self(route: route, providerID: "", modelID: "",
             directProviderID: defaultProviderID ?? "",
             rememberedModels: [.direct: defaultModelID ?? "", .claudeCode: claudeCodeModelID,
                                .museCode: museCodeModelID])
            .reconciling(defaultProviderID: defaultProviderID, defaultModelID: defaultModelID,
                         fallbackClaudeCodeModelID: claudeCodeModelID,
                         fallbackMuseCodeModelID: museCodeModelID, models: models)
    }

    public func selectingRoute(
        _ route: Route, defaultProviderID: String?, defaultModelID: String?,
        fallbackClaudeCodeModelID: String, fallbackMuseCodeModelID: String = "muse-spark-1.2",
        models: [ModelSpec]
    ) -> Self {
        var next = self
        next.route = route
        next = next.reconciling(defaultProviderID: defaultProviderID,
                               defaultModelID: defaultModelID,
                               fallbackClaudeCodeModelID: fallbackClaudeCodeModelID,
                               fallbackMuseCodeModelID: fallbackMuseCodeModelID, models: models)
        next.rememberVisible()
        return next
    }

    public func selectingProvider(
        _ requestedProviderID: String, defaultProviderID: String?, defaultModelID: String?,
        fallbackClaudeCodeModelID: String, fallbackMuseCodeModelID: String = "muse-spark-1.2",
        models: [ModelSpec]
    ) -> Self {
        var next = self
        switch requestedProviderID {
        case Self.claudeCodeProviderID: next.route = .claudeCode
        case Self.museCodeProviderID: next.route = .museCode
        case "": break
        default:
            next.route = .direct
            if requestedProviderID != directProviderID {
                next.directProviderID = requestedProviderID
                next.rememberedModels[.direct] = requestedProviderID == defaultProviderID
                    ? defaultModelID : nil
            }
        }
        return next.selectingRoute(next.route, defaultProviderID: defaultProviderID,
                                   defaultModelID: defaultModelID,
                                   fallbackClaudeCodeModelID: fallbackClaudeCodeModelID,
                                   fallbackMuseCodeModelID: fallbackMuseCodeModelID, models: models)
    }

    public func selectingModel(_ requestedModelID: String, models: [ModelSpec]) -> Self {
        var next = self
        next.modelID = Self.model(preferred: requestedModelID, fallback: modelID,
                                  models: models.filter { $0.providerID == providerID })
        next.rememberVisible()
        return next
    }

    public func reconciling(
        defaultProviderID: String?, defaultModelID: String?, fallbackClaudeCodeModelID: String,
        fallbackMuseCodeModelID: String = "muse-spark-1.2", models: [ModelSpec]
    ) -> Self {
        var next = self
        next.providerID = Self.provider(route: route, preferred: directProviderID,
                                        fallback: defaultProviderID, providers: models.map(\.providerID))
        let fallback: String?
        switch route {
        case .direct: fallback = next.providerID == defaultProviderID ? defaultModelID : nil
        case .claudeCode: fallback = fallbackClaudeCodeModelID
        case .museCode: fallback = fallbackMuseCodeModelID
        }
        let preferred = route == .direct && next.providerID != directProviderID
            ? nil : rememberedModels[route]
        next.modelID = Self.model(preferred: preferred, fallback: fallback,
                                  models: models.filter { $0.providerID == next.providerID })
        return next
    }

    public static func provider(
        route: Route, preferred: String?, fallback: String?, providers: [String]
    ) -> String {
        let compatible = providers.filter {
            switch route {
            case .direct: return $0 != claudeCodeProviderID && $0 != museCodeProviderID
            case .claudeCode: return $0 == claudeCodeProviderID
            case .museCode: return $0 == museCodeProviderID
            }
        }
        if let preferred, compatible.contains(preferred) { return preferred }
        if let fallback, compatible.contains(fallback) { return fallback }
        return compatible.first ?? ""
    }

    public static func model(preferred: String?, fallback: String?, models: [ModelSpec]) -> String {
        if let preferred, models.contains(where: { $0.id == preferred }) { return preferred }
        if let fallback, models.contains(where: { $0.id == fallback }) { return fallback }
        return models.first?.id ?? ""
    }

    private mutating func rememberVisible() {
        if !modelID.isEmpty { rememberedModels[route] = modelID }
        if route == .direct && !providerID.isEmpty { directProviderID = providerID }
    }
}
