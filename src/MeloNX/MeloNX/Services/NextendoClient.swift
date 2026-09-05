import Foundation
import Combine

@MainActor
public final class NextendoClient: ObservableObject {
    public static let shared = NextendoClient()

    @Published public private(set) var session: NextendoSession?
    @Published public private(set) var friends: [NextendoFriend] = []
    @Published public private(set) var presence = NextendoPresence(online: false)
    @Published public private(set) var isConnected = false

    /// Set this to the base HTTPS URL of your private Nextendo server.
    /// Keep production credentials and secrets out of source control.
    public var serverURL: URL

    private let sessionURL: URLSession
    private let keychain: NextendoKeychain
    private var webSocket: URLSessionWebSocketTask?

    public init(
        serverURL: URL = URL(string: "https://nextendo.local")!,
        keychain: NextendoKeychain = .shared,
        urlSession: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.keychain = keychain
        self.sessionURL = urlSession
    }

    public func restoreSession() {
        guard let token = try? keychain.loadToken() else { return }
        Task {
            do {
                let user: NextendoUser = try await request(path: "/api/me", method: "GET", token: token)
                session = NextendoSession(accessToken: token, user: user)
                NotificationCenter.default.post(name: .nextendoSessionChanged, object: session)
                try await refreshFriends()
                connectRealtime()
            } catch {
                try? keychain.deleteToken()
                session = nil
            }
        }
    }

    public func login(username: String, password: String) async throws {
        struct LoginBody: Encodable { let username: String; let password: String }
        struct LoginResponse: Decodable { let accessToken: String; let user: NextendoUser }

        let response: LoginResponse = try await request(
            path: "/api/login",
            method: "POST",
            body: LoginBody(username: username, password: password)
        )

        try keychain.save(token: response.accessToken)
        session = NextendoSession(accessToken: response.accessToken, user: response.user)
        NotificationCenter.default.post(name: .nextendoSessionChanged, object: session)
        try await refreshFriends()
        connectRealtime()
    }

    public func logout() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        try? keychain.deleteToken()
        session = nil
        friends = []
        presence = NextendoPresence(online: false)
        isConnected = false
        NotificationCenter.default.post(name: .nextendoSessionChanged, object: nil)
    }

    public func refreshFriends() async throws {
        guard let token = session?.accessToken else { return }
        friends = try await request(path: "/api/friends", method: "GET", token: token)
    }

    public func setGamePresence(game: String?) async throws {
        guard let token = session?.accessToken else { throw NextendoAPIError(message: "Not signed in.") }
        let body = NextendoPresence(online: game != nil, game: game)
        let _: NextendoPresence = try await request(path: "/api/presence", method: "POST", body: body, token: token)
        presence = body
    }

    private func connectRealtime() {
        guard let token = session?.accessToken else { return }
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        components?.scheme = (components?.scheme == "https") ? "wss" : "ws"
        components?.path = "/api/realtime"
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = sessionURL.webSocketTask(with: request)
        webSocket = task
        task.resume()
        isConnected = true
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        guard let task = webSocket else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handleRealtime(text)
                    }
                    self.receiveNextMessage()
                case .failure:
                    self.isConnected = false
                    self.webSocket = nil
                }
            }
        }
    }

    private func handleRealtime(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data) else { return }

        switch event.type {
        case "friend_online":
            NotificationCenter.default.post(name: .nextendoFriendOnline, object: event)
        case "friend_offline":
            NotificationCenter.default.post(name: .nextendoFriendOffline, object: event)
        case "presence_changed":
            NotificationCenter.default.post(name: .nextendoPresenceChanged, object: event)
        default:
            break
        }
    }

    private struct RealtimeEvent: Decodable {
        let type: String
        let user: String?
        let game: String?
    }

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
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }

        let (data, response) = try await sessionURL.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NextendoAPIError(message: "Invalid server response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(NextendoAPIError.self, from: data))?.message
                ?? "Nextendo server returned HTTP \(http.statusCode)."
            throw NextendoAPIError(message: message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        token: String
    ) async throws -> T {
        try await request(path: path, method: method, body: Optional<String>.none, token: token)
    }
}
