import Foundation

public struct NextendoUser: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let friendCode: String?
    public let avatarURL: URL?

    public init(id: String, username: String, friendCode: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.username = username
        self.friendCode = friendCode
        self.avatarURL = avatarURL
    }
}

public struct NextendoFriend: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let friendCode: String?
    public let online: Bool
    public let game: String?

    public init(id: String, username: String, friendCode: String? = nil, online: Bool = false, game: String? = nil) {
        self.id = id
        self.username = username
        self.friendCode = friendCode
        self.online = online
        self.game = game
    }
}

public struct NextendoSession: Codable, Equatable, Sendable {
    public let accessToken: String
    public let user: NextendoUser

    public init(accessToken: String, user: NextendoUser) {
        self.accessToken = accessToken
        self.user = user
    }
}

public struct NextendoPresence: Codable, Equatable, Sendable {
    public let online: Bool
    public let game: String?

    public init(online: Bool, game: String? = nil) {
        self.online = online
        self.game = game
    }
}

public struct NextendoAPIError: Error, Codable, LocalizedError, Sendable {
    public let message: String

    public var errorDescription: String? { message }
}

public extension Notification.Name {
    static let nextendoFriendOnline = Notification.Name("NextendoFriendOnline")
    static let nextendoFriendOffline = Notification.Name("NextendoFriendOffline")
    static let nextendoPresenceChanged = Notification.Name("NextendoPresenceChanged")
    static let nextendoSessionChanged = Notification.Name("NextendoSessionChanged")
}
