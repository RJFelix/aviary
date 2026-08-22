import CryptoKit
import Foundation

/// OpenAI Codex (ChatGPT) OAuth, and the credential store it shares with the harness.
///
/// **This file is a deliberate one-to-one reimplementation of the harness's own flow**
/// (`packages/ai/src/utils/oauth/openai-codex.ts` and `core/auth-storage.ts`). Every value that
/// reaches an OpenAI server — client id, endpoints, scope, the extra authorize parameters, the
/// PKCE method, the grant bodies — is copied rather than chosen. Third-party harness use sits in
/// a tolerated grey area; looking like a *different* client is what risks being mistaken for
/// credential resale. So the rule for this file is: if a value is sent to OpenAI, it matches
/// the reference exactly, and any difference is a bug rather than an improvement.
///
/// Credentials live in the same `auth.json`, in the same shape, so a login done here works in
/// the harness and vice versa. There is only one account; two stores would mean two logins and
/// a refresh race.
public enum CodexAuth {

    // MARK: Constants — copied, not chosen

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    /// Fixed, because it is registered with the client id. The local server must listen on
    /// exactly this port.
    static let redirectURI = "http://localhost:1455/auth/callback"
    /// Loopback only, matching the reference's `CALLBACK_HOST` default. Binding every interface
    /// would briefly expose the callback — and an authorization code — to the local network.
    static let callbackHost = "127.0.0.1"
    static let scope = "openid profile email offline_access"
    public static let callbackPort: UInt16 = 1455
    /// The claim the account id is nested under inside the access token.
    static let jwtClaimPath = "https://api.openai.com/auth"
    /// Sent as the `originator` on both the authorize URL and every API request. The harness
    /// identifies as `pi`, and so must this: a novel originator is exactly the anomaly that
    /// gets a client flagged.
    public static let originator = "pi"

    // MARK: Credentials

    public struct Credentials: Sendable, Hashable {
        public var access: String
        public var refresh: String
        /// Milliseconds since the epoch, as the harness stores it.
        public var expires: Int
        public var accountId: String

        public var isExpired: Bool {
            // `>=`, matching the harness exactly. No early-refresh window: a different
            // threshold would mean the two clients disagree about whether a token is usable.
            Int(Date().timeIntervalSince1970 * 1000) >= expires
        }

        public var expiresAt: Date {
            Date(timeIntervalSince1970: Double(expires) / 1000)
        }
    }

    // MARK: The shared store

    /// Reads and writes `auth.json` — the harness's file, in the harness's shape.
    public struct Store: Sendable {
        public let url: URL

        public init(home: AgentHome) {
            url = home.authFile
        }

        public init(url: URL) {
            self.url = url
        }

        public func credentials(provider: String = "openai-codex") -> Credentials? {
            guard let data = FileManager.default.contents(atPath: url.path),
                  let root = JSONValue.parse(data),
                  let entry = root[provider],
                  entry["type"]?.stringValue == "oauth",
                  let access = entry["access"]?.stringValue,
                  let refresh = entry["refresh"]?.stringValue,
                  let expires = entry["expires"]?.intValue,
                  let accountId = entry["accountId"]?.stringValue
            else { return nil }
            return Credentials(
                access: access, refresh: refresh, expires: expires, accountId: accountId)
        }

        /// Write credentials back, preserving every other provider's entry untouched.
        ///
        /// Read-modify-write rather than replace: this file is shared with the harness and may
        /// hold API keys for providers Aviary never looked at. The harness takes a real lock
        /// (`proper-lockfile`) around this; Aviary writes atomically instead, which is weaker
        /// against a simultaneous harness refresh and strictly better than a partial file.
        public func save(_ credentials: Credentials, provider: String = "openai-codex") throws {
            var root: [String: JSONValue] = [:]
            if let data = FileManager.default.contents(atPath: url.path),
               case .object(let existing)? = JSONValue.parse(data)
            {
                root = existing
            }
            root[provider] = .object([
                "type": .string("oauth"),
                "access": .string(credentials.access),
                "refresh": .string(credentials.refresh),
                "expires": .number(Double(credentials.expires)),
                "accountId": .string(credentials.accountId),
            ])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(JSONValue.object(root)).write(to: url, options: .atomic)
            // 0600, like the harness. An atomic replace does not inherit the old file's mode.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: Token endpoint

    public enum AuthError: LocalizedError {
        case tokenExchangeFailed(status: Int, body: String)
        case missingFields(String)
        case noAccountID
        case notAuthenticated
        case stateMismatch
        case callbackFailed(String)

        public var errorDescription: String? {
            switch self {
            case .tokenExchangeFailed(let status, let body):
                return "OpenAI Codex token exchange failed (\(status)): \(body)"
            case .missingFields(let body):
                return "OpenAI Codex token response missing fields: \(body)"
            case .noAccountID:
                return "Failed to extract accountId from token"
            case .notAuthenticated:
                return "Not signed in to OpenAI Codex. Run `Aviary --codex-login`."
            case .stateMismatch:
                return "State mismatch"
            case .callbackFailed(let detail):
                return "OAuth callback failed: \(detail)"
            }
        }
    }

    /// `grant_type=refresh_token`, with exactly the fields the harness sends.
    public static func refresh(_ refreshToken: String) async throws -> Credentials {
        try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    static func exchange(code: String, verifier: String) async throws -> Credentials {
        try await postToken([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ])
    }

    static func postToken(_ fields: [String: String]) async throws -> Credentials {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(fields).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.tokenExchangeFailed(
                status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = JSONValue.parse(data),
              let access = json["access_token"]?.stringValue,
              let refresh = json["refresh_token"]?.stringValue,
              let expiresIn = json["expires_in"]?.intValue
        else {
            throw AuthError.missingFields(String(data: data, encoding: .utf8) ?? "")
        }
        guard let accountId = accountID(fromAccessToken: access) else {
            throw AuthError.noAccountID
        }
        return Credentials(
            access: access, refresh: refresh,
            // Milliseconds, computed the same way: now + expires_in * 1000.
            expires: Int(Date().timeIntervalSince1970 * 1000) + expiresIn * 1000,
            accountId: accountId)
    }

    /// `application/x-www-form-urlencoded`, matching `URLSearchParams`: spaces become `+`.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "*-._")
        return fields.keys.sorted().map { key in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let value = (fields[key] ?? "")
                .addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(value)"
        }.joined(separator: "&")
    }

    /// The `chatgpt_account_id` claim, read without verifying the signature.
    ///
    /// Not verifying is correct here and matches the reference: this token came from the token
    /// endpoint over TLS moments ago, and the claim is being used to address a request, not to
    /// authorize one.
    public static func accountID(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let payload = base64URLDecode(String(parts[1])),
              let json = JSONValue.parse(payload),
              // Subscripted directly, not via a dotted path: the claim key is
              // "https://api.openai.com/auth" and a path helper that splits on "." tears it
              // into pieces that match nothing. This silently returned nil until a test
              // asserted the value.
              let claim = json[jwtClaimPath],
              let accountId = claim["chatgpt_account_id"]?.stringValue,
              !accountId.isEmpty
        else { return nil }
        return accountId
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var padded = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64url omits padding; Foundation's decoder requires it.
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }

    // MARK: PKCE

    /// 32 random bytes, base64url, unpadded — then SHA-256 of the *verifier string*, base64url.
    ///
    /// Matching the reference exactly matters: the challenge is computed over the ASCII of the
    /// encoded verifier, not over the raw bytes, and getting that backwards produces a
    /// challenge the server rejects.
    public static func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URLEncode(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return (verifier, base64URLEncode(Data(digest)))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The authorize URL, with every parameter the harness sends and in the same order.
    public static func authorizationURL(
        challenge: String, state: String, originator: String = CodexAuth.originator
    ) -> URL {
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // These three are Codex-specific and not optional in practice: without them the
            // consent screen takes a different shape and the resulting token lacks the
            // organization claims.
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: originator),
        ]
        return components.url!
    }

    public static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts a bare code, a `code#state` pair, a query string, or the whole redirect URL —
    /// the same four shapes the reference accepts, because a person pasting from a browser
    /// gets to choose.
    public static func parseAuthorizationInput(_ input: String) -> (code: String?, state: String?) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (nil, nil) }
        if let url = URL(string: value), url.scheme != nil,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            return (components.queryItems?.first { $0.name == "code" }?.value,
                    components.queryItems?.first { $0.name == "state" }?.value)
        }
        if value.contains("#") {
            let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
            return (parts.first, parts.count > 1 ? parts[1] : nil)
        }
        if value.contains("code=") {
            var components = URLComponents()
            components.query = value
            return (components.queryItems?.first { $0.name == "code" }?.value,
                    components.queryItems?.first { $0.name == "state" }?.value)
        }
        return (value, nil)
    }

    // MARK: Resolving a usable token

    /// A valid access token, refreshing and persisting if the stored one has expired.
    public static func accessToken(store: Store) async throws -> Credentials {
        guard let stored = store.credentials() else { throw AuthError.notAuthenticated }
        guard stored.isExpired else { return stored }
        let refreshed = try await refresh(stored.refresh)
        try store.save(refreshed)
        return refreshed
    }
}
