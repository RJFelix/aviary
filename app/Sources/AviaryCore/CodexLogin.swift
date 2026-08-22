import Foundation
import Network

/// The interactive half of Codex OAuth: a loopback server on port 1455, then a code exchange.
///
/// Faithful to the harness's flow, including the parts that look incidental. The port is not a
/// choice — `http://localhost:1455/auth/callback` is registered against the client id, and any
/// other port is rejected by the authorization server. The success and failure pages are served
/// so the browser lands somewhere deliberate rather than on a connection error.
///
/// Manual paste is supported alongside the callback, as the reference does, because the loopback
/// leg fails in real situations — a browser on another machine, a port already held.
public actor CodexLogin {

    public struct Started: Sendable {
        public var url: URL
        public var state: String
        public var verifier: String
    }

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var state: String = ""
    private var settled = false

    public init() {}

    /// Begin: mint PKCE, start listening, and return the URL to open.
    public func begin() throws -> Started {
        let (verifier, challenge) = CodexAuth.generatePKCE()
        let state = CodexAuth.newState()
        self.state = state
        try startListener()
        return Started(
            url: CodexAuth.authorizationURL(challenge: challenge, state: state),
            state: state, verifier: verifier)
    }

    /// Wait for the browser to come back, or for a timeout.
    public func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.setContinuation(cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CodexAuth.AuthError.callbackFailed(
                    "no response within \(Int(timeout))s — paste the code or URL instead")
            }
            let code = try await group.next()!
            group.cancelAll()
            return code
        }
    }

    private func setContinuation(_ cont: CheckedContinuation<String, Error>) {
        continuation = cont
    }

    private func finish(_ result: Result<String, Error>) {
        guard !settled else { return }
        settled = true
        switch result {
        case .success(let code): continuation?.resume(returning: code)
        case .failure(let error): continuation?.resume(throwing: error)
        }
        continuation = nil
        listener?.cancel()
        listener = nil
    }

    /// Complete the exchange and persist. Verifies `state` first — a mismatch means the
    /// response belongs to a different flow, which is the attack this parameter exists for.
    public func complete(
        code: String, verifier: String, expectedState: String?, store: CodexAuth.Store
    ) async throws -> CodexAuth.Credentials {
        if let expectedState, !expectedState.isEmpty, expectedState != state {
            throw CodexAuth.AuthError.stateMismatch
        }
        let credentials = try await CodexAuth.exchange(code: code, verifier: verifier)
        try store.save(credentials)
        return credentials
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: The loopback server

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: CodexAuth.callbackPort) else {
            throw CodexAuth.AuthError.callbackFailed("bad port")
        }
        // Loopback only, like the reference. Without this NWListener binds every interface and
        // an authorization code is briefly reachable from the local network.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(CodexAuth.callbackHost), port: port)
        let listener: NWListener
        do {
            // `requiredLocalEndpoint` carries both host and port, so it must not be combined
            // with `on:` — passing both makes the bind fail for a reason that looks exactly
            // like the port being taken, which sent me chasing a phantom conflict.
            listener = try NWListener(using: parameters)
        } catch {
            // Report the real reason rather than assuming. "In use" is the common case and
            // worth naming, but guessing it when the cause was a bad parameter wasted a
            // debugging round.
            throw CodexAuth.AuthError.callbackFailed(
                "could not listen on \(CodexAuth.callbackHost):\(CodexAuth.callbackPort) — "
                    + "\(error.localizedDescription). If another sign-in is running, close it, "
                    + "or paste the redirect URL instead.")
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receive(on: connection)
        }
        // Surface a bind failure that arrives asynchronously, which is how NWListener reports
        // an address already in use.
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { await self?.finish(.failure(CodexAuth.AuthError.callbackFailed(
                    "port \(CodexAuth.callbackPort) unavailable: \(error.localizedDescription)"))) }
            }
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    private nonisolated func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)
            else {
                connection.cancel()
                return
            }
            Task { await self.handle(request: text, on: connection) }
        }
    }

    private func handle(request: String, on connection: NWConnection) {
        // Only the request line is needed; the rest of the HTTP request is irrelevant here.
        guard let line = request.split(separator: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(target)")
        else {
            respond(connection, status: "400 Bad Request", body: Self.errorPage("Malformed request."))
            return
        }
        guard components.path == "/auth/callback" else {
            respond(connection, status: "404 Not Found",
                    body: Self.errorPage("Callback route not found."))
            return
        }
        let query = components.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == state else {
            // Answered but not fatal, matching the reference: it responds 400 and keeps
            // waiting. A stray or stale callback must not cancel a login that is still in
            // progress — which is exactly what ending it here did.
            respond(connection, status: "400 Bad Request", body: Self.errorPage("State mismatch."))
            return
        }
        guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            respond(connection, status: "400 Bad Request",
                    body: Self.errorPage("Missing authorization code."))
            return
        }
        respond(connection, status: "200 OK",
                body: Self.successPage("OpenAI authentication completed. You can close this window."))
        finish(.success(code))
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func successPage(_ message: String) -> String {
        page(title: "Signed in", message: message, tint: "#0b5f63")
    }

    static func errorPage(_ message: String) -> String {
        page(title: "Sign-in failed", message: message, tint: "#8e2f45")
    }

    static func page(title: String, message: String, tint: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <body style="margin:0;display:grid;place-items:center;height:100vh;background:#f4f6f6;\
        font:16px/1.5 -apple-system,system-ui,sans-serif;color:#151c1e">
        <main style="text-align:center;max-width:34rem;padding:2rem">
        <h1 style="font-size:1.25rem;margin:0 0 .5rem;color:\(tint)">\(title)</h1>
        <p style="margin:0;color:#3e4b4d">\(message)</p></main>
        """
    }
}
