import Foundation
import Combine
import AuthenticationServices
import CryptoKit
import Security
import UIKit

/// Current Nextendo Network client for iOS.
///
/// Authentication uses the first-party public emulator OAuth client with
/// Authorization Code + PKCE. The password is entered on nextendo.network;
/// MeloNext never receives or stores it.
@MainActor
public final class NextendoClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = NextendoClient()

    public static let defaultServerURL = URL(string: "https://nextendo.network")!
    public static let emulatorClientID = "nextendo-emulator"
    public static let oauthScopes = ["identity", "friends"]

    @Published public private(set) var session: NextendoSession?
    @Published public private(set) var friends: [NextendoFriend] = []
    @Published public private(set) var presence = NextendoPresence(status: 0)
    @Published public private(set) var isConnected = false
    @Published public private(set) var isAuthenticating = false

    public var serverURL: URL

    private let sessionURL: URLSession
    private let keychain: NextendoKeychain
    private var authSession: ASWebAuthenticationSession?
    private var heartbeatTimer: Timer?
    private var lastPresence = NextendoPresence(status: 0)

    public init(
        serverURL: URL = NextendoClient.defaultServerURL,
        keychain: NextendoKeychain = .shared,
        urlSession: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.keychain = keychain
        self.sessionURL = urlSession
        super.init()
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
            ?? UIWindow(frame: UIScreen.main.bounds)
    }

    public func restoreSession() {
        guard let token = try? keychain.loadToken(), let token, !token.isEmpty else {
            return
        }

        Task {
            do {
                let account = try await fetchAccount(token: token)
                session = NextendoSession(nexToken: token, user: account)
                isConnected = true
                postSessionChanged()
                try await refreshFriends()
                startHeartbeat()
            } catch {
                try? keychain.deleteToken()
                session = nil
                friends = []
                isConnected = false
            }
        }
    }

    /// Opens Nextendo's hosted login/consent UI and exchanges the returned
    /// authorization code for the emulator's NEX token.
    public func signIn() async throws {
        guard !isAuthenticating else { return }

        isAuthenticating = true
        defer {
            isAuthenticating = false
            authSession = nil
        }

        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.codeChallenge(verifier)

        // The current Nextendo first-party emulator client accepts any loopback
        // port. PKCE protects the short-lived authorization code.
        let port = Self.randomLoopbackPort()
        let redirectURI = "http://127.0.0.1:\(port)/oauth2redirect/melonext"

        var components = URLComponents(
            url: serverURL.appendingPathComponent("api/oauth/authorize"),
            resolvingAgainstBaseURL: false
        )!

        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.emulatorClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.oauthScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: Self.randomURLSafeString(byteCount: 16))
        ]

        guard let authorizeURL = components.url else {
            throw NextendoAPIError(message: "Could not create the Nextendo authorization URL.")
        }

        let callbackURL = try await authenticate(
            authorizeURL: authorizeURL,
            callbackScheme: "http"
        )

        let queryItems = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            throw NextendoAPIError(message: "Nextendo authorization failed: \(error)")
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw NextendoAPIError(message: "Nextendo did not return an authorization code.")
        }

        let token = try await exchangeCode(
            code: code,
            verifier: verifier,
            redirectURI: redirectURI
        )

        try keychain.save(token: token.nexToken)

        session = NextendoSession(nexToken: token.nexToken, user: token.user)
        isConnected = true
        postSessionChanged()

        try await refreshFriends()
        startHeartbeat()
    }

    /// Compatibility entry point for older MeloNext UI code.
    public func login() async throws {
        try await signIn()
    }

    public func logout() {
        stopHeartbeat()
        authSession?.cancel()
        authSession = nil
        try? keychain.deleteToken()
        session = nil
        friends = []
        lastPresence = NextendoPresence(status: 0)
        presence = lastPresence
        isConnected = false
        postSessionChanged()
    }

    public func refreshFriends() async throws {
        guard let token = session?.nexToken else { return }

        struct FriendsResponse: Decodable {
            let friends: [NextendoFriend]
        }

        let response: FriendsResponse = try await request(
            path: "/api/friends",
            method: "GET",
            token: token
        )

        friends = response.friends
    }

    /// Current Nextendo presence payload:
    /// status + app_id + app_detail + app_field.
    public func setGamePresence(
        appID: String?,
        detail: String? = nil,
        appField: Data = Data(),
        playing: Bool = true
    ) async throws {
        guard let token = session?.nexToken else {
            throw NextendoAPIError(message: "Not signed in.")
        }

        let next = NextendoPresence(
            status: playing ? 2 : 1,
            appID: appID ?? "",
            appDetail: detail ?? "",
            appField: appField.base64URLEncodedString()
        )

        let _: EmptyResponse = try await request(
            path: "/api/presence",
            method: "POST",
            body: next,
            token: token
        )

        lastPresence = next
        presence = next
    }

    /// Compatibility overload for the previous client API.
    public func setGamePresence(game: String?) async throws {
        try await setGamePresence(appID: game, playing: game != nil)
    }

    public func clearGamePresence() async {
        guard session != nil else { return }

        let next = NextendoPresence(status: 1)

        do {
            let _: EmptyResponse = try await request(
                path: "/api/presence",
                method: "POST",
                body: next,
                token: session?.nexToken
            )
        } catch {
            // Presence is best effort during shutdown.
        }

        lastPresence = next
        presence = next
    }

    private func startHeartbeat() {
        stopHeartbeat()

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in
                guard self.session != nil, self.lastPresence.status != 0 else { return }

                do {
                    let _: EmptyResponse = try await self.request(
                        path: "/api/presence",
                        method: "POST",
                        body: self.lastPresence,
                        token: self.session?.nexToken
                    )
                } catch {
                    // Presence is best effort; never interrupt emulation.
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func authenticate(
        authorizeURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] url, error in
                Task { @MainActor in
                    self?.authSession = nil

                    if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(
                            throwing: error ?? NextendoAPIError(
                                message: "Nextendo sign-in was cancelled."
                            )
                        )
                    }
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session

            guard session.start() else {
                authSession = nil
                continuation.resume(
                    throwing: NextendoAPIError(
                        message: "Could not start the Nextendo sign-in session."
                    )
                )
                return
            }
        }
    }

    private struct OAuthTokenResponse: Decodable {
        let nexToken: String
        let account: OAuthAccount

        enum CodingKeys: String, CodingKey {
            case nexToken = "nex_token"
            case account
        }
    }

    private struct OAuthAccount: Decodable {
        let pid: UInt64
        let username: String
        let friendCode: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case pid
            case username
            case friendCode = "friend_code"
            case displayName = "display_name"
        }

        var user: NextendoUser {
            NextendoUser(
                id: String(pid),
                username: username,
                friendCode: friendCode,
                displayName: displayName
            )
        }
    }

    private func exchangeCode(
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> (nexToken: String, user: NextendoUser) {
        var request = URLRequest(
            url: serverURL.appendingPathComponent("api/oauth/token")
        )

        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: Self.emulatorClientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]

        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await sessionURL.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NextendoAPIError(message: "Invalid Nextendo token response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(OAuthServerError.self, from: data)
            throw NextendoAPIError(
                message: serverError?.localizedMessage
                    ?? "Nextendo token exchange failed (HTTP \(http.statusCode))."
            )
        }

        let result = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return (result.nexToken, result.account.user)
    }

    private struct OAuthServerError: Decodable {
        let error: String?
        let message: String?

        var localizedMessage: String {
            error ?? message ?? "Unknown Nextendo OAuth error."
        }
    }

    private func fetchAccount(token: String) async throws -> NextendoUser {
        struct MeResponse: Decodable {
            let account: OAuthAccount
        }

        let response: MeResponse = try await request(
            path: "/api/me",
            method: "GET",
            token: token
        )

        return response.account.user
    }

    private struct EmptyResponse: Decodable {}

    private func request<T: Decodable, B: Encodable>(
        path: String,
        method: String,
        body: B? = nil,
        token: String? = nil
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: serverURL) else {
            throw NextendoAPIError(message: "Invalid Nextendo server URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await sessionURL.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NextendoAPIError(message: "Invalid Nextendo server response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw NextendoAPIError(
                    message: "Nextendo session expired or was revoked."
                )
            }

            let message = (try? JSONDecoder().decode(
                NextendoAPIError.self,
                from: data
            ))?.message ?? "Nextendo server returned HTTP \(http.statusCode)."

            throw NextendoAPIError(message: message)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)

        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomLoopbackPort() -> Int {
        Int.random(in: 49152...65535)
    }

    private func postSessionChanged() {
        NotificationCenter.default.post(
            name: .nextendoSessionChanged,
            object: session
        )
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
