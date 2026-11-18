import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum AuthError: LocalizedError {
    case notLoggedIn
    case missingClientID
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "尚未登入 Spotify"
        case .missingClientID: return "請先填入 Spotify Client ID"
        case let .http(code, body): return "HTTP \(code)：\(body.prefix(200))"
        }
    }
}

/// Spotify OAuth（Authorization Code + PKCE，不需要 client secret）
@MainActor
final class SpotifyAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let redirectURI = "dynlyrics://callback"
    private static let scopes = "user-read-currently-playing user-read-playback-state"
    private static let refreshKey = "refresh_token"

    @Published private(set) var isLoggedIn = false
    @Published var lastError: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?
    private var refreshTask: Task<String, Error>?

    private var clientID: String {
        AppSettings.shared.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override init() {
        super.init()
        isLoggedIn = Keychain.get(Self.refreshKey) != nil
    }

    // MARK: - Login

    func login() {
        let clientID = self.clientID
        guard !clientID.isEmpty else { lastError = AuthError.missingClientID.errorDescription; return }
        lastError = nil

        let verifier = Self.randomString(64)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]

        let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: "dynlyrics") { url, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authSession = nil
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.lastError = "登入失敗：\(error.localizedDescription)"
                    }
                    return
                }
                let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
                guard let code = items?.first(where: { $0.name == "code" })?.value else {
                    self.lastError = "登入失敗：\(items?.first(where: { $0.name == "error" })?.value ?? "沒有收到授權碼")"
                    return
                }
                await self.exchange(code: code, verifier: verifier)
            }
        }
        session.presentationContextProvider = self
        authSession = session
        session.start()
    }

    func logout() {
        Keychain.set(nil, for: Self.refreshKey)
        accessToken = nil
        expiry = .distantPast
        isLoggedIn = false
    }

    /// access token 失效（例如收到 401）時呼叫，下次會自動 refresh
    func invalidate() {
        accessToken = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    // MARK: - Tokens

    func validToken() async throws -> String {
        if let token = accessToken, expiry > Date().addingTimeInterval(60) { return token }
        if let task = refreshTask { return try await task.value }
        guard let refresh = Keychain.get(Self.refreshKey) else { throw AuthError.notLoggedIn }
        let clientID = self.clientID

        let task = Task { () throws -> String in
            defer { self.refreshTask = nil }
            do {
                let r = try await self.tokenRequest([
                    "grant_type": "refresh_token",
                    "refresh_token": refresh,
                    "client_id": clientID,
                ])
                self.store(r)
                return r.access_token
            } catch let AuthError.http(code, body) where code == 400 {
                // refresh token 被撤銷或 client ID 改了
                self.logout()
                self.lastError = "登入已失效，請重新登入"
                throw AuthError.http(code, body)
            }
        }
        refreshTask = task
        return try await task.value
    }

    private func exchange(code: String, verifier: String) async {
        do {
            let r = try await tokenRequest([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": clientID,
                "code_verifier": verifier,
            ])
            store(r)
        } catch {
            lastError = "登入失敗：\(error.localizedDescription)"
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private func store(_ r: TokenResponse) {
        accessToken = r.access_token
        expiry = Date().addingTimeInterval(TimeInterval(r.expires_in))
        if let rt = r.refresh_token { Keychain.set(rt, for: Self.refreshKey) }
        isLoggedIn = true
        lastError = nil
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AuthError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Helpers

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
