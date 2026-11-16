import Foundation

/// The installed Muse Code command line host.
///
/// Muse's account and model catalog are owned by the native `muse serve` process. Aviary only
/// asks that process for its bounded projections; it never reads Muse credential files or puts a
/// provider key into a prompt or transcript.
public enum MuseCode {
    public struct Discovery: Sendable, Equatable {
        public let models: [ModelSpec]
        public let authenticated: Bool
        public let detail: String?

        public init(models: [ModelSpec], authenticated: Bool, detail: String? = nil) {
            self.models = models
            self.authenticated = authenticated
            self.detail = detail
        }
    }
    private static let installCandidates = [
        "/opt/homebrew/bin/muse",
        "/usr/local/bin/muse",
        "~/.local/bin/muse",
        "~/.muse/bin/muse",
    ]

    /// Find an installed executable, preferring stable install locations over PATH shims.
    public static func locate() async -> String? {
        let fm = FileManager.default
        for candidate in installCandidates {
            let path = (candidate as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        if let found = await Shell.which("muse"), !isEphemeral(found),
           fm.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    static func isEphemeral(_ path: String) -> Bool {
        ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"]
            .contains { path.hasPrefix($0) }
    }

    /// Environment variables that can redirect an account-login run to a metered provider key.
    /// Keep this list conservative in the direction that protects the account lane: a key or
    /// provider override inherited from a parent shell must not silently win over Muse login.
    public static let strippedVariables = [
        "META_API_KEY", "MUSE_API_KEY", "MUSE_MODEL", "MUSE_PROVIDER", "MUSE_BASE_URL",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_MODEL",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
        "GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI",
        "XAI_API_KEY", "GROK_API_KEY", "TOGETHER_API_KEY", "MISTRAL_API_KEY",
        "COHERE_API_KEY", "DEEPSEEK_API_KEY", "PERPLEXITY_API_KEY",
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AWS_BEARER_TOKEN_BEDROCK", "CLAUDECODE", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    ]

    public static func scrubbedEnvironment(
        base: [String: String]? = nil, adding extras: [String: String] = [:]
    ) -> [String: String] {
        var environment = base ?? ProcessEnvironment.shared.snapshot
        for variable in strippedVariables { environment.removeValue(forKey: variable) }
        for (key, value) in extras { environment[key] = value }
        if (environment["PATH"] ?? "").isEmpty {
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        }
        return environment
    }

    /// A bounded account projection. It does not expose credential material.
    public static func authStatus(binary: String? = nil) async -> MuseMSPAccountState? {
        let executable = if let binary { binary } else { await locate() }
        guard let executable else { return nil }
        do {
            let owner = try await MuseMSPProcess.launch(
                executable: executable, cwd: FileManager.default.currentDirectoryPath,
                environment: scrubbedEnvironment(), experimentalAPI: true)
            defer { Task { await owner.stop() } }
            return try await owner.connection.accountRead()
        } catch {
            return nil
        }
    }

    /// A bounded runtime catalog. The raw host response is projected into typed model rows.
    public static func catalog(binary: String? = nil) async -> MuseMSPModelCatalog? {
        let executable = if let binary { binary } else { await locate() }
        guard let executable else { return nil }
        do {
            let owner = try await MuseMSPProcess.launch(
                executable: executable, cwd: FileManager.default.currentDirectoryPath,
                environment: scrubbedEnvironment(), experimentalAPI: true)
            defer { Task { await owner.stop() } }
            return try await owner.connection.modelList()
        } catch {
            return nil
        }
    }

    /// Discover account state and the host's current model catalog through one bounded process.
    /// The returned models carry only fields reported by Muse; absent prices and context remain
    /// absent rather than being filled from an unrelated provider catalog.
    public static func discover(binary: String? = nil) async -> Discovery {
        let executable = if let binary { binary } else { await locate() }
        guard let executable else {
            return Discovery(models: [], authenticated: false, detail: "Muse executable unavailable")
        }
        do {
            let owner = try await MuseMSPProcess.launch(
                executable: executable, cwd: FileManager.default.currentDirectoryPath,
                environment: scrubbedEnvironment(), experimentalAPI: true)
            defer { Task { await owner.stop() } }
            let account = try? await owner.connection.accountRead()
            let catalog = try await owner.connection.modelList()
            let models = catalog.models.map(modelSpec)
            let state = account?.state.lowercased() ?? "unknown"
            let authenticated = ["accountlogin", "loggedin", "authenticated", "ready"].contains(state)
            let detail = account?.label ?? (account?.credentialRequired == true ? "Muse login required" : nil)
            return Discovery(models: models, authenticated: authenticated, detail: detail)
        } catch {
            return Discovery(models: [], authenticated: false, detail: error.localizedDescription)
        }
    }

    /// Muse does not publish price or context metadata through the stable catalog. Unknown
    /// values stay unknown; this must not manufacture list prices or a context window.
    public static func modelSpec(for model: String) -> ModelSpec {
        ModelSpec(rpc: .object([
            "id": .string(model),
            "provider": .string("muse-code"),
        ]))
    }

    private static func modelSpec(_ model: MuseMSPModelCatalog.Model) -> ModelSpec {
        var raw = model.raw.objectValue ?? [:]
        raw["id"] = .string(model.id)
        raw["provider"] = .string("muse-code")
        raw["name"] = .string(model.label)
        return ModelSpec(rpc: .object(raw))
    }
}
