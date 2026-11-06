import AppKit
import CryptoKit
import Foundation
import Network

/// Google OAuth 2.0 for installed apps: Authorization Code + PKCE with a
/// loopback (127.0.0.1) redirect, as recommended by Google for desktop apps.
///
/// Sign-in happens in the user's normal browser, so Notchling never sees the
/// Google password and works with Workspace SSO. The refresh token is stored
/// in the login Keychain.
@MainActor
final class GoogleAuth {
    struct Tokens {
        var accessToken: String
        var expiresAt: Date
    }

    enum AuthError: LocalizedError {
        case missingClientID
        case cancelled
        case stateMismatch
        case server(String)
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .missingClientID: return "Add your Google OAuth client ID in Settings first."
            case .cancelled: return "Sign-in was cancelled or timed out."
            case .stateMismatch: return "Sign-in response didn't match the request."
            case .server(let msg): return msg
            case .notSignedIn: return "Not signed in to Google."
            }
        }
    }

    private let settings: AppSettings
    private var tokens: Tokens?
    private var refreshTask: Task<String, Error>?
    private var pendingServer: LoopbackServer?
    private static let refreshTokenKey = "google.refreshToken"

    init(settings: AppSettings) { self.settings = settings }

    var hasRefreshToken: Bool { Keychain.get(Self.refreshTokenKey) != nil }

    func scopes() -> [String] {
        var s = ["openid", "email", "https://www.googleapis.com/auth/calendar.readonly"]
        if settings.gmailEnabled { s.append("https://www.googleapis.com/auth/gmail.readonly") }
        if settings.tasksEnabled { s.append("https://www.googleapis.com/auth/tasks") }
        return s
    }

    // MARK: Sign in

    func signIn() async throws {
        let clientID = settings.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw AuthError.missingClientID }

        pendingServer?.stop()
        let server = LoopbackServer()
        pendingServer = server
        defer { server.stop(); if pendingServer === server { pendingServer = nil } }

        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Self.randomURLSafe(bytes: 16)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes().joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)

        let params = try await server.waitForRedirect(timeout: 300)
        if let error = params["error"] { throw AuthError.server("Google returned: \(error)") }
        guard params["state"] == state else { throw AuthError.stateMismatch }
        guard let code = params["code"] else { throw AuthError.cancelled }

        let json = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "client_secret": settings.googleClientSecret,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        guard let refresh = json["refresh_token"] as? String else {
            throw AuthError.server("Google didn't return a refresh token.")
        }
        Keychain.set(refresh, for: Self.refreshTokenKey)
        storeAccessToken(json)
    }

    func cancelSignIn() {
        pendingServer?.cancel()
    }

    func signOut() async {
        if let refresh = Keychain.get(Self.refreshTokenKey) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formEncode(["token": refresh])
            _ = try? await URLSession.shared.data(for: req)
        }
        Keychain.delete(Self.refreshTokenKey)
        tokens = nil
    }

    // MARK: Tokens

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let tokens, tokens.expiresAt > Date().addingTimeInterval(60) {
            return tokens.accessToken
        }
        if let refreshTask { return try await refreshTask.value }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw AuthError.notSignedIn }
            defer { self.refreshTask = nil }
            guard let refresh = Keychain.get(Self.refreshTokenKey) else { throw AuthError.notSignedIn }
            let json = try await self.tokenRequest([
                "client_id": self.settings.googleClientID,
                "client_secret": self.settings.googleClientSecret,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            return self.storeAccessToken(json)
        }
        refreshTask = task
        return try await task.value
    }

    @discardableResult
    private func storeAccessToken(_ json: [String: Any]) -> String {
        let token = json["access_token"] as? String ?? ""
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        tokens = Tokens(accessToken: token, expiresAt: Date().addingTimeInterval(expiresIn))
        return token
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(form)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let desc = json["error_description"] as? String ?? json["error"] as? String ?? "Token request failed"
            if (json["error"] as? String) == "invalid_grant" {
                Keychain.delete(Self.refreshTokenKey)
                throw AuthError.notSignedIn
            }
            throw AuthError.server(desc)
        }
        return json
    }

    // MARK: Helpers

    private static func randomURLSafe(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return Data(buffer).base64URLEncoded()
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)!
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback redirect receiver

/// A one-shot HTTP listener bound to 127.0.0.1 only (never reachable from the
/// network, so it doesn't trigger the firewall's incoming-connections prompt).
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "notchling.oauth.loopback")
    private var listener: NWListener?
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var redirectContinuation: CheckedContinuation<[String: String], Error>?
    private var receivedParams: [String: String]?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)
        self.listener = listener
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.portContinuation = cont
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            self.portContinuation?.resume(returning: port)
                            self.portContinuation = nil
                        }
                    case .failed(let error):
                        self.portContinuation?.resume(throwing: error)
                        self.portContinuation = nil
                        self.finish(.failure(error))
                    default: break
                    }
                }
                listener.newConnectionHandler = { conn in self.handle(conn) }
                listener.start(queue: self.queue)
            }
        }
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let params = self.receivedParams { cont.resume(returning: params); return }
                self.redirectContinuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(GoogleAuth.AuthError.cancelled))
                }
            }
        }
    }

    func cancel() { queue.async { self.finish(.failure(GoogleAuth.AuthError.cancelled)) } }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        if case .success(let params) = result { receivedParams = params }
        guard let cont = redirectContinuation else { return }
        redirectContinuation = nil
        cont.resume(with: result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            let comps = URLComponents(string: "http://127.0.0.1\(target)")
            let items = comps?.queryItems ?? []
            var params: [String: String] = [:]
            for item in items { params[item.name] = item.value ?? "" }

            let isOAuth = params["code"] != nil || params["error"] != nil
            let body = isOAuth
                ? "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:80px;background:#111;color:#eee\"><h2>Notchling is connected</h2><p>You can close this tab.</p></body></html>"
                : "Not found"
            let response = "HTTP/1.1 \(isOAuth ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isOAuth { self.finish(.success(params)) }
        }
    }
}
