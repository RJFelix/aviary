import Foundation

/// The non-secret result of selecting an in-house model.
///
/// A selection deliberately contains identifiers and routing metadata only. In particular it
/// does not carry a ``ProviderSpec``: that type contains the configured `apiKey` expression, and
/// a literal expression can itself be a credential. Callers can use `providerID` to look up the
/// already-captured provider configuration immediately before constructing a provider, while a
/// manifest, receipt, or diagnostic can safely persist this value.
public struct InHouseModelSelection: Codable, Equatable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let api: String
    public let providerIsBuiltIn: Bool
    public let modelIsBuiltIn: Bool
    /// A versioned, non-secret attestation of the route and captured availability facts used to
    /// make this choice. Credential values and key expressions are intentionally absent.
    public let configurationDigest: String

    public init(
        providerID: String,
        modelID: String,
        api: String,
        providerIsBuiltIn: Bool,
        modelIsBuiltIn: Bool,
        configurationDigest: String
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.api = api
        self.providerIsBuiltIn = providerIsBuiltIn
        self.modelIsBuiltIn = modelIsBuiltIn
        self.configurationDigest = configurationDigest
    }

    public var qualifiedID: String { "\(providerID)/\(modelID)" }
    public var selectionDigest: String { configurationDigest }
    public var routeDigest: String { configurationDigest }
}

/// Why a model reference could not be selected.
///
/// Associated values are bounded identifiers, never an api-key expression or a resolved
/// credential. The resolver intentionally does not echo the original reference because callers
/// may have obtained it from an untrusted or secret-bearing input field.
public enum InHouseModelSelectionError: LocalizedError, Equatable, Sendable {
    case emptyReference
    case invalidReference
    case invalidConfiguration
    case duplicateProvider
    case duplicateModel
    case unknownProvider
    case unknownModel
    case unavailableProvider
    case unavailableModel
    case ambiguousModel([String])
    case noAvailableModels
    case unsupportedProvider

    public var errorDescription: String? {
        switch self {
        case .emptyReference:
            return "The model reference is empty."
        case .invalidReference:
            return "The model reference is invalid."
        case .invalidConfiguration:
            return "The model configuration is invalid."
        case .duplicateProvider:
            return "The model configuration contains duplicate providers."
        case .duplicateModel:
            return "The model configuration contains duplicate models."
        case .unknownProvider:
            return "The requested provider is not configured."
        case .unknownModel:
            return "The requested model is not configured for that provider."
        case .unavailableProvider:
            return "The requested provider has no captured usable credentials."
        case .unavailableModel:
            return "The requested model has no captured usable provider."
        case .ambiguousModel:
            // Never include arbitrary configured ids in a user-facing diagnostic. The bounded
            // candidates remain available to a typed caller for disambiguation.
            return "The model reference is ambiguous."
        case .noAvailableModels:
            return "No available in-house models are configured."
        case .unsupportedProvider:
            return "This provider is not an in-house HTTP provider."
        }
    }
}

/// Pure model/provider selection for an in-house Work Host.
///
/// The caller supplies the complete configuration, auth summary, and a captured environment
/// snapshot. This type never consults ``ProcessEnvironment.shared`` and never resolves a shell
/// command, so selection is stable across a GUI/daemon boundary and cannot change halfway through
/// a launch. Secret resolution remains a separate, explicitly effectful provider-construction
/// step. This is the canonical selection policy intended to replace ``AgentCLI.resolve``; the
/// latter remains a UI call site until the service-backed launch path is cut over.
public enum InHouseModelResolver {
    private static let maximumIdentifierBytes = 256
    private static let maximumAPIBytes = 128
    private static let maximumReferenceBytes = 1_024
    private static let maximumAmbiguousCandidates = 16
    private static let maximumHeaders = 64
    private static let maximumHeaderBytes = 4_096
    private static let maximumURLBytes = 8_192
    private static let digestVersion = "aviary-inhouse-route-v2"
    public struct Inputs: Sendable {
        public let config: ModelsConfig
        public let auth: AuthInfo
        public let environment: [String: String]
        /// Metadata-only local credentials captured by the host.  Values never participate in
        /// selection or its digest.
        public let localSecrets: [LocalSecretMetadata]
        public let preferences: ModelPreferences

        public init(
            config: ModelsConfig,
            auth: AuthInfo = AuthInfo(),
            environment: [String: String] = [:],
            localSecrets: [LocalSecretMetadata] = [],
            preferences: ModelPreferences = ModelPreferences()
        ) {
            self.config = config
            self.auth = auth
            self.environment = environment
            self.localSecrets = localSecrets
            self.preferences = preferences
        }
    }

    /// Resolve a qualified `provider/model`, a bare model id, or the configured default.
    ///
    /// Qualified references are authoritative: a missing or unavailable provider/model is an
    /// error and never falls through to a similarly named bare model. Bare references must be
    /// unique among available providers. With no reference, the first enabled candidate wins in
    /// preference order, then canonical provider/model order. Explicit references may still name
    /// a disabled model so existing durable choices remain reopenable.
    public static func resolve(
        _ reference: String?, inputs: Inputs
    ) -> Result<InHouseModelSelection, InHouseModelSelectionError> {
        let candidateResult = candidates(from: inputs)
        guard case .success(let providers) = candidateResult else {
            if case .failure(let error) = candidateResult { return .failure(error) }
            return .failure(.invalidConfiguration)
        }

        if let reference {
            if reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(.emptyReference)
            }
            guard isValidReference(reference) else { return .failure(.invalidReference) }
            if reference.contains("/") {
                let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    return .failure(.unknownModel)
                }
                let matchingProviders = providers.filter { $0.id == parts[0] }
                guard !matchingProviders.isEmpty else { return .failure(.unknownProvider) }
                guard matchingProviders.count == 1, let provider = matchingProviders.first else {
                    return .failure(.unknownProvider)
                }
                guard let model = provider.models.first(where: { $0.id == parts[1] }) else {
                    return .failure(.unknownModel)
                }
                guard isSupported(provider, model: model) else {
                    return .failure(.unsupportedProvider)
                }
                guard isAvailable(provider, inputs: inputs) else {
                    return .failure(.unavailableProvider)
                }
                return .success(selection(provider: provider, model: model, inputs: inputs))
            }

            let configuredMatches = providers.flatMap { provider in
                provider.models.filter { $0.id == reference }.map { (provider, $0) }
            }
            let supportedMatches = configuredMatches.filter {
                isSupported($0.0, model: $0.1)
            }
            let availableMatches = supportedMatches.filter {
                isAvailable($0.0, inputs: inputs)
            }
            guard !availableMatches.isEmpty else {
                if !supportedMatches.isEmpty { return .failure(.unavailableModel) }
                return .failure(.unknownModel)
            }
            if availableMatches.count > 1 {
                let ids = Array(availableMatches.map { "\($0.0.id)/\($0.1.id)" }.sorted()
                    .prefix(maximumAmbiguousCandidates))
                return .failure(.ambiguousModel(ids))
            }
            let hit = availableMatches[0]
            return .success(selection(provider: hit.0, model: hit.1, inputs: inputs))
        }

        let available = providers
            .filter { isAvailable($0, inputs: inputs) }
            .flatMap { provider in
                provider.models.filter { isSupported(provider, model: $0) }.map { (provider, $0) }
            }
            .filter { inputs.preferences.isEnabled($0.1) }
            .sorted { lhs, rhs in
                let leftRank = inputs.preferences.rank(lhs.1)
                let rightRank = inputs.preferences.rank(rhs.1)
                if leftRank != rightRank { return leftRank < rightRank }
                if lhs.0.id != rhs.0.id { return lhs.0.id < rhs.0.id }
                return lhs.1.id < rhs.1.id
        }
        guard let first = available.first else { return .failure(.noAvailableModels) }
        return .success(selection(provider: first.0, model: first.1, inputs: inputs))
    }

    private static func candidates(
        from inputs: Inputs
    ) -> Result<[ProviderSpec], InHouseModelSelectionError> {
        var providers = inputs.config.providers
        var providerIDs = Set<String>()
        for provider in providers {
            guard isValidIdentifier(provider.id), providerIDs.insert(provider.id).inserted else {
                return .failure(providerIDs.contains(provider.id) ? .duplicateProvider : .invalidConfiguration)
            }
            guard provider.api.map(isValidAPI) ?? true,
                  provider.apiKeyExpression.map({ $0.utf8.count <= 4_096 }) ?? true,
                  provider.authHeader.map(isValidHeaderText) ?? true,
                  isValidRouteURL(provider.baseURL),
                  provider.headers.count <= maximumHeaders,
                  provider.headers.allSatisfy({ key, value in
                      !key.isEmpty && isValidHeaderText(key) && isValidHeaderText(value)
                  }) else {
                return .failure(.invalidConfiguration)
            }
            if let expression = provider.apiKeyExpression,
               case .secretReference(let name) = ApiKeyForm.classify(expression),
               !LocalSecretStore.isValidName(name) {
                return .failure(.invalidConfiguration)
            }
            var modelIDs = Set<String>()
            for model in provider.models {
                guard model.providerID == provider.id,
                      isValidIdentifier(model.id, allowSlash: true),
                      modelIDs.insert(model.id).inserted else {
                    return .failure(modelIDs.contains(model.id) ? .duplicateModel : .invalidConfiguration)
                }
                guard model.api.map(isValidAPI) ?? true,
                      model.api == nil || model.api == provider.api,
                      isValidAPI(model.api ?? provider.api ?? "openai-completions") else {
                    return .failure(.invalidConfiguration)
                }
            }
        }
        let codex = BuiltInProviders.openAICodex(auth: inputs.auth)
        if !providers.contains(where: { $0.id == codex.id }) {
            providers.append(codex)
        }
        // Claude Code is deliberately not appended here. It is a subscription CLI, not an
        // in-house HTTP provider; selecting it would make the daemon try to construct the wrong
        // client and would blur the Work Host's provider boundary.
        return .success(providers.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            let leftModels = lhs.models.map(\.id).joined(separator: "\u{1f}")
            let rightModels = rhs.models.map(\.id).joined(separator: "\u{1f}")
            return leftModels < rightModels
        })
    }

    private static func isSupported(_ provider: ProviderSpec, model: ModelSpec) -> Bool {
        provider.id != "claude-code"
            && (model.api ?? provider.api ?? "openai-completions") != "claude-code-cli"
    }

    private static func isAvailable(_ provider: ProviderSpec, inputs: Inputs) -> Bool {
        if provider.id == "openai-codex" && provider.isBuiltIn {
            return inputs.auth.providers.contains(provider.id)
        }
        // ChatProviderRouting does not consume custom auth.json entries. Only the built-in Codex
        // route above has an OAuth-backed provider factory, so coincidental auth names cannot
        // make a missing HTTP endpoint look reachable.
        guard let baseURL = provider.baseURL.flatMap(URL.init(string:)),
              baseURL.scheme?.isEmpty == false, baseURL.host?.isEmpty == false else { return false }
        guard let expression = provider.apiKeyExpression, !expression.isEmpty else {
            // A valid unauthenticated local HTTP endpoint is allowed.
            return true
        }
        switch ApiKeyForm.classify(expression) {
        case .environmentVariable(let name):
            return !(inputs.environment[name]?.isEmpty ?? true)
        case .literal:
            return true
        case .command:
            // A command requires an effectful shell and cannot be resolved from a captured
            // environment alone. Failing closed here prevents restart-time selection drift.
            return false
        case .secretReference(let name):
            guard LocalSecretStore.isValidName(name),
                  let rawOrigin = provider.baseURL,
                  let origin = LocalSecretStore.normalizedHTTPSOrigin(rawOrigin) else {
                return false
            }
            return inputs.localSecrets.contains {
                $0.name == name
                    && $0.allowedProviderID == provider.id
                    && $0.allowedOrigin == origin
            }
        }
    }

    private static func selection(
        provider: ProviderSpec, model: ModelSpec, inputs: Inputs
    ) -> InHouseModelSelection {
        let effectiveAPI = model.api ?? provider.api ?? "openai-completions"
        return InHouseModelSelection(
            providerID: provider.id,
            modelID: model.id,
            api: effectiveAPI,
            providerIsBuiltIn: provider.isBuiltIn,
            modelIsBuiltIn: model.isBuiltIn,
            configurationDigest: digest(
                provider: provider, model: model, effectiveAPI: effectiveAPI, inputs: inputs))
    }

    private static func isValidReference(_ reference: String) -> Bool {
        guard reference.utf8.count <= maximumReferenceBytes,
              reference == reference.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.unicodeScalars.contains(where: { $0.properties.isWhitespace
                  || $0.value < 0x20 }) else { return false }
        if reference.contains("/") {
            let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 && isValidIdentifier(parts[0]) && isValidIdentifier(parts[1], allowSlash: true)
        }
        return isValidIdentifier(reference, allowSlash: false)
    }

    private static func isValidIdentifier(_ value: String, allowSlash: Bool = false) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumIdentifierBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.unicodeScalars.contains(where: {
            $0.properties.isWhitespace || $0.value < 0x20 || (!allowSlash && $0.value == 0x2f)
        })
    }

    private static func isValidAPI(_ value: String) -> Bool {
        guard value.utf8.count <= maximumAPIBytes else { return false }
        return isValidIdentifier(value)
    }

    private static func digest(
        provider: ProviderSpec, model: ModelSpec, effectiveAPI: String, inputs: Inputs
    ) -> String {
        var builder = DigestBuilder()
        builder.append(digestVersion)
        builder.append(provider.id)
        builder.append(model.id)
        builder.append(effectiveAPI)
        builder.append(provider.isBuiltIn)
        builder.append(model.isBuiltIn)
        // ChatProviderRouting constructs the provider from ProviderSpec, so its baseURL is the
        // effective endpoint. ModelSpec often copies that value during models.json decoding;
        // using model.baseURL here would make a later provider endpoint change invisible.
        builder.append(safeURL(provider.baseURL))
        builder.append(model.reasoning)
        builder.append(model.contextWindow.map(String.init) ?? "none")
        builder.append(model.maxTokens.map(String.init) ?? "none")
        for modality in model.inputModalities.sorted() {
            builder.append(modality)
        }
        if let thinkingLevelMap = model.thinkingLevelMap {
            builder.append("thinking-map-present")
            for level in thinkingLevelMap.keys.sorted() {
                builder.append(level)
                if let mapped = thinkingLevelMap[level] {
                    builder.append("mapped")
                    builder.append(mapped ?? "")
                } else {
                    builder.append("unmapped")
                }
            }
        } else {
            builder.append("thinking-map-absent")
        }
        builder.append(provider.authHeader ?? "")
        for header in provider.headers.keys.sorted() {
            builder.append(header)
            // Extra header values affect routing/provider behavior, unlike the separately
            // resolved apiKey expression. Attest their value without placing raw bytes in the
            // manifest-visible route identity.
            builder.append(hexDigest(provider.headers[header] ?? ""))
        }
        if inputs.auth.providers.contains(provider.id) {
            builder.append("stored-auth")
        } else if let expression = provider.apiKeyExpression, !expression.isEmpty {
            switch ApiKeyForm.classify(expression) {
            case .environmentVariable(let name):
                builder.append("environment")
                builder.append(name)
                builder.append(!(inputs.environment[name]?.isEmpty ?? true))
            case .literal:
                builder.append("literal-present")
            case .command:
                builder.append("command-unresolved")
            case .secretReference(let name):
                builder.append("secret-reference")
                builder.append(name)
                let available = inputs.localSecrets.contains {
                    $0.name == name
                        && $0.allowedProviderID == provider.id
                        && $0.allowedOrigin == (provider.baseURL.flatMap(
                            LocalSecretStore.normalizedHTTPSOrigin) ?? "invalid-origin")
                }
                builder.append(available)
            }
        } else {
            builder.append("no-key")
        }
        // The separately resolved API credential remains outside durable selection identity.
        // Static extra headers are executable route configuration and are attested above.
        return hexDigest(builder.data)
    }

    private static func isValidRouteURL(_ raw: String?) -> Bool {
        guard let raw else { return true }
        guard raw.utf8.count <= maximumURLBytes,
              let components = URLComponents(string: raw),
              components.scheme?.isEmpty == false,
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return false }
        return true
    }

    private static func isValidHeaderText(_ value: String) -> Bool {
        value.utf8.count <= maximumHeaderBytes
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private static func safeURL(_ raw: String?) -> String {
        guard let raw, let components = URLComponents(string: raw) else { return "invalid-url" }
        var safe = URLComponents()
        safe.scheme = components.scheme
        safe.host = components.host
        safe.port = components.port
        safe.path = components.path
        return safe.string ?? "invalid-url"
    }

    private struct DigestBuilder {
        var data = Data()

        mutating func append(_ value: String) {
            let bytes = Data(value.utf8)
            data.append(Data("\(bytes.count):".utf8))
            data.append(bytes)
        }

        mutating func append(_ value: Bool) { append(value ? "1" : "0") }
    }

    private static func hexDigest(_ value: String) -> String {
        hexDigest(Data(value.utf8))
    }

    private static func hexDigest(_ data: Data) -> String {
        AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
