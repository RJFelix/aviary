import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Model & provider records

public struct ModelSpec: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String?
    public var providerID: String
    public var api: String?
    public var baseURL: String?
    public var reasoning: Bool
    public var contextWindow: Int?
    public var maxTokens: Int?
    public var inputModalities: [String]
    public var costInput: Double?
    public var costOutput: Double?
    public var costCacheRead: Double?
    public var costCacheWrite: Double?
    /// Present for providers that remap thinking levels; a `null` mapping means that
    /// level silently does not reach the model.
    public var thinkingLevelMap: [String: String?]?
    /// True when the model came from the harness's built-in catalog rather than models.json.
    public var isBuiltIn: Bool = false

    public var displayName: String { name ?? id }
    public var qualifiedID: String { "\(providerID)/\(id)" }

    public var supportsImages: Bool { inputModalities.contains("image") }

    /// Blended cost of a million tokens at a typical 3:1 input:output split.
    public var blendedCostPerMTok: Double? {
        guard let i = costInput, let o = costOutput,
              i.isFinite, o.isFinite, i >= 0, o >= 0 else { return nil }
        return i * 0.75 + o * 0.25
    }

    /// Thinking levels that this provider explicitly maps to no reasoning.
    public var deadThinkingLevels: [String] {
        guard let map = thinkingLevelMap else { return [] }
        return map.filter { $0.value == nil }.keys.sorted()
    }

    init(id: String, providerID: String, json: JSONValue, provider: JSONValue?, isBuiltIn: Bool = false) {
        self.id = id
        self.providerID = providerID
        self.isBuiltIn = isBuiltIn
        name = json["name"]?.stringValue
        api = json["api"]?.stringValue ?? provider?["api"]?.stringValue
        baseURL = json["baseUrl"]?.stringValue ?? provider?["baseUrl"]?.stringValue
        reasoning = json["reasoning"]?.boolValue ?? false
        contextWindow = json["contextWindow"]?.intValue
        maxTokens = json["maxTokens"]?.intValue
        inputModalities = (json["input"]?.arrayValue ?? []).compactMap(\.stringValue)
        costInput = json.path("cost.input")?.doubleValue
        costOutput = json.path("cost.output")?.doubleValue
        costCacheRead = json.path("cost.cacheRead")?.doubleValue
        costCacheWrite = json.path("cost.cacheWrite")?.doubleValue
        if let map = json["thinkingLevelMap"]?.objectValue {
            thinkingLevelMap = map.mapValues { $0.isNull ? nil : $0.stringValue }
        }
    }

    /// Built from an RPC `Model` object, which is the authoritative runtime view.
    public init(rpc json: JSONValue) {
        id = json["id"]?.stringValue ?? "?"
        providerID = json["provider"]?.stringValue ?? "?"
        name = json["name"]?.stringValue
        api = json["api"]?.stringValue
        baseURL = json["baseUrl"]?.stringValue
        reasoning = json["reasoning"]?.boolValue ?? false
        contextWindow = json["contextWindow"]?.intValue
        maxTokens = json["maxTokens"]?.intValue
        inputModalities = (json["input"]?.arrayValue ?? []).compactMap(\.stringValue)
        costInput = json.path("cost.input")?.doubleValue
        costOutput = json.path("cost.output")?.doubleValue
        costCacheRead = json.path("cost.cacheRead")?.doubleValue
        costCacheWrite = json.path("cost.cacheWrite")?.doubleValue
        if let map = json["thinkingLevelMap"]?.objectValue {
            thinkingLevelMap = map.mapValues { $0.isNull ? nil : $0.stringValue }
        }
        isBuiltIn = false
    }
}

public struct ProviderSpec: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String?
    public var baseURL: String?
    public var api: String?
    /// The raw `apiKey` field — a form, not a secret. Never a resolved value.
    public var apiKeyExpression: String?
    public var authHeader: String?
    public var headers: [String: String]
    public var models: [ModelSpec]
    /// Providers the harness ships (OAuth-authed, not in models.json).
    public var isBuiltIn: Bool = false
    /// True when auth.json holds credentials for this provider.
    public var hasStoredAuth: Bool = false
    public var authKind: String?

    public var displayName: String { name ?? id }

    public var keyForm: ApiKeyForm? {
        apiKeyExpression.map(ApiKeyForm.classify)
    }
}

// MARK: - models.json

/// Reads and writes `~/.prime/agent/models.json`.
///
/// Edits go through a re-parse of the original bytes so unknown fields survive: this file
/// is hand-maintained and holds provider quirks (`compat`, `modelOverrides`) that Aviary
/// has no business dropping just because it doesn't model them.
public struct ModelsConfig: Sendable {
    public var providers: [ProviderSpec]
    public var raw: JSONValue
    public var fileURL: URL
    public var exists: Bool

    public static func load(home: AgentHome, auth: AuthInfo? = nil) -> ModelsConfig {
        let url = home.modelsFile
        guard let data = FileManager.default.contents(atPath: url.path),
              let raw = JSONValue.parse(data)
        else {
            return ModelsConfig(providers: [], raw: .object([:]), fileURL: url, exists: false)
        }

        var out: [ProviderSpec] = []
        for (pid, pv) in (raw["providers"]?.objectValue ?? [:]) {
            var p = ProviderSpec(
                id: pid,
                name: pv["name"]?.stringValue,
                baseURL: pv["baseUrl"]?.stringValue,
                api: pv["api"]?.stringValue,
                apiKeyExpression: pv["apiKey"]?.stringValue,
                authHeader: pv["authHeader"]?.stringValue,
                headers: (pv["headers"]?.objectValue ?? [:]).compactMapValues(\.stringValue),
                models: [])
            p.models = (pv["models"]?.arrayValue ?? []).compactMap { mv in
                guard let mid = mv["id"]?.stringValue else { return nil }
                return ModelSpec(id: mid, providerID: pid, json: mv, provider: pv)
            }.sorted { $0.id < $1.id }
            p.hasStoredAuth = auth?.providers.contains(pid) ?? false
            p.authKind = auth?.kinds[pid]
            out.append(p)
        }
        return ModelsConfig(
            providers: out.sorted { $0.id < $1.id }, raw: raw, fileURL: url, exists: true)
    }

    /// Write a modified copy back, preserving every field we didn't touch.
    ///
    /// A timestamped backup is made first. The harness's own convention (`models.json.bak-*`
    /// files left by past hand-edits) already established this; Aviary just does it every time.
    public func write(mutating mutate: (inout JSONValue) -> Void) throws {
        var next = raw
        mutate(&next)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            let stamp = DateFormatter.backupStamp.string(from: Date())
            let backup = fileURL.deletingLastPathComponent()
                .appending(path: "models.json.aviary-bak-\(stamp)")
            try? fm.copyItem(at: fileURL, to: backup)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(next)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension DateFormatter {
    static let backupStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

// MARK: - auth.json

/// Which providers have stored credentials — names and auth kinds only.
///
/// The file holds live OAuth tokens at mode 0600. Aviary reads the key set and the `type`
/// field and nothing else; no code path in the app can put a token on screen.
public struct AuthInfo: Sendable {
    public var providers: Set<String> = []
    public var kinds: [String: String] = [:]
    public var fileExists: Bool = false
    public var permissionsAreTight: Bool = true

    public init(
        providers: Set<String> = [],
        kinds: [String: String] = [:],
        fileExists: Bool = false,
        permissionsAreTight: Bool = true
    ) {
        self.providers = providers
        self.kinds = kinds
        self.fileExists = fileExists
        self.permissionsAreTight = permissionsAreTight
    }

    public static func load(home: AgentHome) -> AuthInfo {
        var info = AuthInfo()
        let url = home.authFile
        guard let data = FileManager.default.contents(atPath: url.path),
              let v = JSONValue.parse(data), let obj = v.objectValue
        else { return info }
        info.fileExists = true
        for (k, val) in obj {
            info.providers.insert(k)
            if let t = val["type"]?.stringValue { info.kinds[k] = t }
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let perms = attrs[.posixPermissions] as? NSNumber
        {
            info.permissionsAreTight = (perms.intValue & 0o077) == 0
        }
        return info
    }
}

// MARK: - API key resolution

public enum ApiKeyForm: Sendable, Hashable {
    /// `!command` — executed through `$SHELL -c`, stdout trimmed, result cached.
    case command(String)
    /// A bare environment-variable name.
    case environmentVariable(String)
    /// A literal credential sitting in the config file.
    case literal
    /// A name resolved from Aviary's local secure credential store.  This is deliberately a
    /// separate form: a missing or invalid reference must never become a literal credential.
    case secretReference(String)

    public static func classify(_ expression: String) -> ApiKeyForm {
        if expression.hasPrefix("!") { return .command(String(expression.dropFirst())) }
        // Reserve the whole @secret namespace.  A malformed spelling such as "@secret" is
        // represented by an empty name and is therefore rejected by the secure resolver rather
        // than silently becoming a literal credential.
        if expression == "@secret" || expression.hasPrefix("@secret") {
            guard expression.hasPrefix(LocalSecretStore.referencePrefix) else {
                return .secretReference("")
            }
            return .secretReference(String(expression.dropFirst(LocalSecretStore.referencePrefix.count)))
        }
        // The harness looks up *any* string in the environment first, so the distinction
        // is about intent. All-caps-with-underscores is unambiguous intent.
        let looksLikeVar = !expression.isEmpty
            && expression.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
        return looksLikeVar ? .environmentVariable(expression) : .literal
    }

    public var label: String {
        switch self {
        case .command: return "Shell command"
        case .environmentVariable: return "Environment variable"
        case .literal: return "Literal value"
        case .secretReference: return "Aviary secure credential"
        }
    }
}

public struct ApiKeyResolution: Sendable {
    public enum Outcome: Sendable, Equatable {
        case resolved
        /// The scoped credential is stored; decryption by the executing host is not yet proven.
        case secretReferenceStored
        /// The killer case: a bare variable name that isn't set, so the harness sends the
        /// *name itself* as the credential and the server answers 401.
        case fellBackToLiteralName(String)
        case commandFailed(String)
        case empty
        case noKeyConfigured
        case secretReferenceInvalid
        case secretReferenceUnavailable

        public var isProblem: Bool {
            switch self {
            case .resolved, .secretReferenceStored, .noKeyConfigured: return false
            default: return true
                }
        }
    }

    public var form: ApiKeyForm?
    public var outcome: Outcome
    /// First and last few characters only, so you can tell one key from another.
    public var masked: String?
    public var length: Int = 0
    public var explanation: String

    public var ok: Bool { !outcome.isProblem }
}

/// Resolves a provider's `apiKey` expression exactly the way the harness does, and
/// explains the result.
///
/// This exists because of one specific, expensive failure. The harness resolves a bare
/// environment-variable name client-side; when the variable is *absent* it does not
/// error — it falls back to treating the string as a literal and sends the variable's
/// **name** as the credential. The server then says
/// `Received=LITE****_KEY, expected to start with 'sk-'`, which reads like a typo in the
/// config rather than a missing export. It bites hardest from a GUI app, whose environment
/// comes from launchd and not your shell. Aviary resolves the same expression through the
/// login-shell environment it captured at startup, and names the failure out loud.
public enum ApiKeyResolver {
    public static func resolve(
        _ expression: String?,
        home: AgentHome? = nil,
        providerID: String? = nil,
        origin: String? = nil,
        secretStore: LocalSecretStore? = nil
    ) async -> ApiKeyResolution {
        guard let expression, !expression.isEmpty else {
            return ApiKeyResolution(
                form: nil, outcome: .noKeyConfigured, masked: nil,
                explanation: "No apiKey set. Fine for a local server that doesn't check one, "
                    + "and for built-in providers that authenticate by OAuth.")
        }

        let form = ApiKeyForm.classify(expression)
        switch form {
        case .command(let cmd):
            let shell = ProcessEnvironment.shared.value("SHELL") ?? "/bin/zsh"
            let r = await Shell.run(shell, ["-c", cmd], timeout: 20)
            guard case .success(let res) = r else {
                return ApiKeyResolution(
                    form: form, outcome: .commandFailed("could not launch \(shell)"),
                    masked: nil, explanation: "Could not run the shell to evaluate the command.")
            }
            let value = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !res.ok {
                return ApiKeyResolution(
                    form: form, outcome: .commandFailed(res.stderr), masked: nil,
                    explanation: "The command exited \(res.exitCode). The harness treats that as "
                        + "no credential at all and sends the request unauthenticated.")
            }
            if value.isEmpty {
                return ApiKeyResolution(
                    form: form, outcome: .empty, masked: nil,
                    explanation: "The command succeeded but printed nothing.")
            }
            return ApiKeyResolution(
                form: form, outcome: .resolved, masked: mask(value), length: value.count,
                explanation: "Resolved by running the command. The harness caches this for the "
                    + "process lifetime.")

        case .environmentVariable(let name):
            if let value = ProcessEnvironment.shared.value(name) {
                let source = ProcessEnvironment.shared.isLoginShellEnvironment
                    ? "your login shell environment" : "the process environment"
                return ApiKeyResolution(
                    form: form, outcome: .resolved, masked: mask(value), length: value.count,
                    explanation: "$\(name) is set in \(source).")
            }
            return ApiKeyResolution(
                form: form, outcome: .fellBackToLiteralName(name), masked: nil,
                explanation: "$\(name) is not set, so the harness will send the literal string "
                    + "\"\(name)\" as the credential and the provider will answer 401. This is "
                    + "the failure that reads like a config typo. Either export \(name), or use "
                    + "the launcher-independent form: !zsh -ic 'printf %s \"$\(name)\"'")

        case .literal:
            return ApiKeyResolution(
                form: form, outcome: .resolved, masked: mask(expression),
                length: expression.count,
                explanation: "A literal credential in models.json. Works, but it lives in a "
                    + "plaintext file — prefer an environment variable or the !command form.")

        case .secretReference(let name):
            guard !name.isEmpty,
                  let home,
                  let providerID,
                  let origin else {
                return ApiKeyResolution(
                    form: form, outcome: .secretReferenceInvalid, masked: nil,
                    explanation: "The secure credential reference is missing its provider scope.")
            }
            do {
                let store = secretStore ?? LocalSecretStore(home: home)
                guard try store.hasScopedMetadata(
                    name: name, providerID: providerID, origin: origin) else {
                    return ApiKeyResolution(
                        form: form, outcome: .secretReferenceUnavailable, masked: nil,
                        explanation: "The referenced secure credential is unavailable.")
                }
                return ApiKeyResolution(
                    form: form, outcome: .secretReferenceStored, masked: nil, length: 0,
                    explanation: "A credential is saved for this provider and server. The agent service must have Keychain access before it can use it; authorize it from Secrets if needed.")
            } catch {
                // Keep missing, invalid, provider-mismatched, and origin-mismatched records
                // indistinguishable to diagnostics.  None may fall through to a literal.
                return ApiKeyResolution(
                    form: form, outcome: .secretReferenceUnavailable, masked: nil,
                    explanation: "The referenced secure credential is unavailable.")
            }
        }
    }

    static func mask(_ s: String) -> String {
        guard s.count > 10 else { return String(repeating: "•", count: s.count) }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    /// Resolve the actual credential only for the in-memory provider construction boundary.
    /// This value is never returned in ``ApiKeyResolution`` or a diagnostic.
    public static func resolveActual(
        _ expression: String?,
        home: AgentHome? = nil,
        providerID: String? = nil,
        origin: String? = nil,
        secretStore: LocalSecretStore? = nil
    ) async -> String? {
        guard let expression, !expression.isEmpty else { return nil }
        switch ApiKeyForm.classify(expression) {
        case .command(let cmd):
            let shell = ProcessEnvironment.shared.value("SHELL") ?? "/bin/zsh"
            guard case .success(let r) = await Shell.run(shell, ["-c", cmd], timeout: 20), r.ok
            else { return nil }
            let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        case .environmentVariable(let name):
            return ProcessEnvironment.shared.value(name)
        case .literal:
            return expression
        case .secretReference:
            guard let home, let providerID, let origin else { return nil }
            do {
                return try (secretStore ?? LocalSecretStore(home: home)).resolve(
                    expression: expression, providerID: providerID, origin: origin)
            } catch {
                return nil
            }
        }
    }
}

// MARK: - Provider reachability

public struct ProviderTestResult: Sendable {
    public var providerID: String
    public var modelID: String?
    public var ok: Bool
    public var httpStatus: Int?
    public var latency: TimeInterval
    public var detail: String
    /// Text the model actually produced, when the round trip completed.
    public var completion: String?
    public var keyResolution: ApiKeyResolution?
    public var testedAt: Date = Date()
}

/// Sends a real, minimal completion to a provider and reports what came back.
///
/// A reachability check that stops at "the endpoint answered" is worth very little here:
/// the harness needs a route that streams *and* issues tool calls, and routes that flatten
/// the message array into one prompt answer text perfectly while never calling a tool. So
/// this test asks for a token and reports what the endpoint said — enough to separate a
/// misresolved key, a wrong base URL, and a model id the server doesn't have.
public enum ProviderTester {
    public static func test(
        provider: ProviderSpec,
        model: ModelSpec?,
        timeout: TimeInterval = 45,
        home: AgentHome? = nil,
        secretStore: LocalSecretStore? = nil
    ) async -> ProviderTestResult {
        let started = Date()
        // This operation is explicitly requested by the user, unlike background preflight.
        let credentialStore = secretStore ?? LocalSecretStore(home: home ?? .default,
            allowAuthenticationUI: true)
        // Test the same provider-level route that ChatProviderRouting uses for live Work.
        // A model's display metadata must not redirect credential delivery in this screen.
        let origin = provider.baseURL
        let keyResolution = await ApiKeyResolver.resolve(
            provider.apiKeyExpression,
            home: home,
            providerID: provider.id,
            origin: origin,
            secretStore: credentialStore)

        switch keyResolution.outcome {
        case .secretReferenceInvalid, .secretReferenceUnavailable:
            return ProviderTestResult(
                providerID: provider.id, modelID: model?.id, ok: false, httpStatus: nil,
                latency: Date().timeIntervalSince(started),
                detail: "The provider's secure credential could not be resolved.",
                keyResolution: keyResolution)
        default:
            break
        }

        guard let baseURLString = provider.baseURL,
              let base = URL(string: baseURLString)
        else {
            return ProviderTestResult(
                providerID: provider.id, modelID: model?.id, ok: false, httpStatus: nil,
                latency: 0,
                detail: "No baseUrl configured for this provider, so there is nothing to call. "
                    + "Built-in providers authenticate through their own OAuth flow — use the "
                    + "harness's `auth` command for those.",
                keyResolution: keyResolution)
        }

        let api = provider.api ?? "openai-completions"
        let modelID = model?.id ?? ""

        // Exercise Grok's actual streaming adapter, including its terminal proof. A bare 200
        // with sixteen reasoning tokens is not a successful completion test.
        if api == "xai-responses" {
            let key = await ApiKeyResolver.resolveActual(provider.apiKeyExpression,
                home: home, providerID: provider.id, origin: baseURLString, secretStore: credentialStore)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var completion = ""
            var completed = false
            do {
                let client = XAIResponsesProvider(id: provider.id, baseURL: base, apiKey: key, session: session)
                for try await event in client.stream(ChatRequest(model: modelID,
                    messages: [.user("Reply with the single word: ok")], maxTokens: 512, reasoningEffort: "low")) {
                    switch event {
                    case .textDelta(let text): completion += text
                    case .done(let reason): completed = reason == "completed"
                    default: break
                    }
                }
                let safe = key.map { completion.replacingOccurrences(of: $0, with: "<redacted>") } ?? completion
                return ProviderTestResult(providerID: provider.id, modelID: modelID,
                    ok: completed && !safe.isEmpty, httpStatus: 200,
                    latency: Date().timeIntervalSince(started),
                    detail: completed && !safe.isEmpty ? "Grok response completed." : "Grok did not complete the test response.",
                    completion: safe.isEmpty ? nil : String(safe.prefix(1_000)), keyResolution: keyResolution)
            } catch {
                let status: Int?
                let detail: String
                if case ChatError.http(let code, let body) = error {
                    status = code
                    let parsed = JSONValue.parse(Data(body.utf8))
                    let message = parsed?.path("error.message")?.stringValue
                        ?? parsed?["message"]?.stringValue ?? body
                    let safe = key.map { message.replacingOccurrences(of: $0, with: "<redacted>") } ?? message
                    detail = "Grok rejected the test: " + String(safe.prefix(1_000))
                } else {
                    status = nil
                    detail = "Grok could not complete the test. Check API access, model availability, and your saved key."
                }
                return ProviderTestResult(providerID: provider.id, modelID: modelID, ok: false,
                    httpStatus: status, latency: Date().timeIntervalSince(started),
                    detail: detail,
                    keyResolution: keyResolution)
            }
        }

        var request: URLRequest
        var body: [String: JSONValue]

        switch api {
        case "anthropic-messages":
            request = URLRequest(url: base.appending(path: "v1/messages"))
            body = [
                "model": .string(modelID),
                "max_tokens": .number(16),
                "messages": .array([.object([
                    "role": .string("user"),
                    "content": .string("Reply with the single word: ok"),
                ])]),
            ]
        case "openai-responses", "openai-codex-responses", "xai-responses":
            request = URLRequest(url: base.appending(path: "responses"))
            body = [
                "model": .string(modelID),
                "input": .string("Reply with the single word: ok"),
                "max_output_tokens": .number(16),
            ]
        case "google-generative-ai":
            request = URLRequest(url: base.appending(
                path: "v1beta/models/\(modelID):generateContent"))
            body = [
                "contents": .array([.object([
                    "parts": .array([.object(["text": .string("Reply with the single word: ok")])]),
                ])]),
            ]
        default:  // openai-completions and compatible
            request = URLRequest(url: base.appending(path: "chat/completions"))
            body = [
                "model": .string(modelID),
                "max_tokens": .number(16),
                "messages": .array([.object([
                    "role": .string("user"),
                    "content": .string("Reply with the single word: ok"),
                ])]),
            ]
        }

        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aviary/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in provider.headers { request.setValue(v, forHTTPHeaderField: k) }

        // Send whatever the harness would send — including the literal variable name in
        // the failure case, so the 401 the user sees here is the 401 they'd get for real.
        let credential: String? = {
            switch keyResolution.outcome {
            case .resolved, .secretReferenceStored: return nil  // resolved privately below
            case .fellBackToLiteralName(let name): return name
            default: return nil
            }
        }()

        var sentKey = credential
        if [.resolved, .secretReferenceStored].contains(keyResolution.outcome), let expr = provider.apiKeyExpression {
            sentKey = await resolveActual(
                expr, home: home, providerID: provider.id, origin: origin,
                secretStore: credentialStore)
            if case .secretReference = ApiKeyForm.classify(expr), sentKey == nil {
                return ProviderTestResult(
                    providerID: provider.id, modelID: model?.id, ok: false, httpStatus: nil,
                    latency: Date().timeIntervalSince(started),
                    detail: "The provider's secure credential could not be resolved.",
                    keyResolution: keyResolution)
            }
        }

        if let sentKey {
            if let header = provider.authHeader {
                request.setValue(sentKey, forHTTPHeaderField: header)
            } else if api == "anthropic-messages" {
                request.setValue(sentKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else if api == "google-generative-ai" {
                request.setValue(sentKey, forHTTPHeaderField: "x-goog-api-key")
            } else {
                request.setValue("Bearer \(sentKey)", forHTTPHeaderField: "Authorization")
            }
        }

        let enc = JSONEncoder()
        request.httpBody = try? enc.encode(JSONValue.object(body))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let v = JSONValue.parse(data)

            if (200..<300).contains(status) {
                let text = extractCompletion(v, api: api)
                return ProviderTestResult(
                    providerID: provider.id, modelID: model?.id, ok: true, httpStatus: status,
                    latency: elapsed,
                    detail: text.isEmpty
                        ? "HTTP \(status) with an empty completion. The endpoint is reachable and "
                            + "authenticated, but returned no content — a shape this harness's "
                            + "tool loop cannot use."
                        : "HTTP \(status). Round trip completed.",
                    completion: text.isEmpty ? nil : text,
                    keyResolution: keyResolution)
            }

            // Do not surface provider response bodies: gateways sometimes echo an
            // Authorization value in an error envelope.  The status is sufficient to diagnose
            // reachability without creating a second secret-bearing output channel.
            var detail = "HTTP \(status). The provider rejected the test request."
            if status == 401 || status == 403 {
                if case .fellBackToLiteralName(let name) = keyResolution.outcome {
                    detail += "\n\nThis is the missing-export case: $\(name) is not set, so the "
                        + "variable name was sent as the credential."
                }
            }
            return ProviderTestResult(
                providerID: provider.id, modelID: model?.id, ok: false, httpStatus: status,
                latency: elapsed, detail: detail, keyResolution: keyResolution)
        } catch {
            return ProviderTestResult(
                providerID: provider.id, modelID: model?.id, ok: false, httpStatus: nil,
                latency: Date().timeIntervalSince(started),
                detail: error.localizedDescription, keyResolution: keyResolution)
        }
    }

    /// Resolve to the actual secret for the duration of one request. Never stored, never
    /// returned to the UI layer.
    static func resolveActual(
        _ expression: String,
        home: AgentHome? = nil,
        providerID: String? = nil,
        origin: String? = nil,
        secretStore: LocalSecretStore? = nil
    ) async -> String? {
        await ApiKeyResolver.resolveActual(
            expression,
            home: home,
            providerID: providerID,
            origin: origin,
            secretStore: secretStore)
    }

    static func extractCompletion(_ v: JSONValue?, api: String) -> String {
        guard let v else { return "" }
        // Try every shape rather than switching on api: gateways proxy one API's shape
        // through another's endpoint often enough that being permissive is correct.
        if let s = v.path("choices.0.message.content")?.stringValue { return s }
        if let s = v.path("content.0.text")?.stringValue { return s }
        if let s = v.path("candidates.0.content.parts.0.text")?.stringValue { return s }
        if let arr = v["output"]?.arrayValue {
            for item in arr {
                if let s = item.path("content.0.text")?.stringValue { return s }
            }
        }
        if let s = v["output_text"]?.stringValue { return s }
        return ""
    }

    static func errorMessage(_ v: JSONValue?) -> String? {
        guard let v else { return nil }
        return v.path("error.message")?.stringValue
            ?? v["error"]?.stringValue
            ?? v["message"]?.stringValue
            ?? v["detail"]?.stringValue
    }
}

/// Which client serves a provider's declared `api`.
///
/// One factory, because it was two: `AgentCLI` had a Codex case, `InHouseDriver` did not, and
/// the GUI therefore sent Codex traffic to the completions client —
/// `chatgpt.com/backend-api/chat/completions`, which answers `404 {"detail":"Not Found"}`. That
/// reads as a broken model rather than as a missing case, so it survived until somebody tried
/// to resume a Codex session from the app. Two switch statements over the same enum is the
/// shape of that bug; one is not.
public enum ChatProviderRouting {

    public enum RoutingError: LocalizedError, Equatable {
        case notSignedIn(String)
        case noBaseURL(String)
        case secretUnavailable

        public var errorDescription: String? {
            switch self {
            case .notSignedIn(let id):
                return "Not signed in to \(id). Run `Aviary --codex-login`, or sign in from "
                    + "the Models tab."
            case .noBaseURL(let id):
                return "Provider \(id) has no baseUrl."
            case .secretUnavailable:
                return "The provider's secure credential could not be resolved."
            }
        }
    }

    /// Whether a route builds its URL from the provider's `baseUrl`.
    ///
    /// Codex carries its own endpoint, so a missing `baseUrl` must not stop it starting —
    /// while for the others it is a real configuration error worth reporting up front.
    public static func needsBaseURL(_ api: String?) -> Bool {
        api != "openai-codex-responses"
    }

    /// Always true: there is a default. Present so a test can assert that a new api name is
    /// deliberately routed rather than accidentally unhandled.
    public static func isKnown(_ api: String?) -> Bool { true }

    /// The client for this provider, or why there isn't one.
    ///
    /// `resolveSecret` is injected so this is testable without shelling out to a `!command`
    /// key expression — on this machine one of them goes through `zsh -ic`.
    public static func makeProvider(
        spec: ProviderSpec,
        model: ModelSpec,
        home: AgentHome,
        sessionID: String = UUID().uuidString,
        resolveSecret: ((String?) async -> String?)? = nil
    ) async -> Result<ChatProvider, RoutingError> {
        #if !os(Linux)
        if spec.api == "openai-codex-responses" {
            // OAuth rather than a key, and resolved up front so a missing login is an error at
            // launch rather than a 401 three turns in.
            let store = CodexAuth.Store(home: home)
            guard store.credentials() != nil else {
                return .failure(.notSignedIn(spec.id))
            }
            return .success(CodexResponsesProvider(
                id: spec.id, store: store, model: model,
                baseURL: spec.baseURL, sessionID: sessionID))
        }
        #endif
        guard let baseURL = spec.baseURL.flatMap(URL.init(string:)) else {
            return .failure(.noBaseURL(spec.id))
        }
        let providerOrigin = spec.baseURL
        let key: String?
        if let resolveSecret {
            key = await resolveSecret(spec.apiKeyExpression)
        } else {
            key = await ApiKeyResolver.resolveActual(
                spec.apiKeyExpression, home: home, providerID: spec.id, origin: providerOrigin)
        }
        if let expression = spec.apiKeyExpression,
           case .secretReference = ApiKeyForm.classify(expression), key == nil {
            return .failure(.secretUnavailable)
        }
        if spec.api == "xai-responses" {
            return .success(XAIResponsesProvider(
                id: spec.id, baseURL: baseURL, apiKey: key))
        }
        if spec.api == "anthropic-messages" {
            return .success(AnthropicMessagesProvider(
                id: spec.id, baseURL: baseURL, apiKey: key, extraHeaders: spec.headers))
        }
        // Most vendors speak the completions shape, so it is the useful default for an api
        // this build does not recognise — served rather than refused.
        return .success(OpenAICompletionsProvider(
            id: spec.id, baseURL: baseURL, apiKey: key, extraHeaders: spec.headers))
    }
}
