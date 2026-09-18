import Foundation

public struct NextendoUser: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let friendCode: String?
    public let displayName: String?
    public let avatarURL: URL?

    public init(
        id: String,
        username: String,
        friendCode: String? = nil,
        displayName: String? = nil,
        avatarURL: URL? = nil
    ) {
        self.id = id
        self.username = username
        self.friendCode = friendCode
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    public var pid: UInt64? { UInt64(id) }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case friendCode = "friend_code"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

public struct NextendoFriend: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let name: String?
    public let friendCode: String?
    public let nsa: String?
    public let onlineStatus: Int
    public let appID: String?
    public let appDetail: String?

    public init(
        id: String,
        username: String,
        name: String? = nil,
        friendCode: String? = nil,
        nsa: String? = nil,
        onlineStatus: Int = 0,
        appID: String? = nil,
        appDetail: String? = nil
    ) {
        self.id = id
        self.username = username
        self.name = name
        self.friendCode = friendCode
        self.nsa = nsa
        self.onlineStatus = onlineStatus
        self.appID = appID
        self.appDetail = appDetail
    }

    public var online: Bool { onlineStatus != 0 }
    public var game: String? { appID }

    enum CodingKeys: String, CodingKey {
        case id = "pid"
        case username
        case name
        case friendCode = "friend_code"
        case nsa
        case presence
    }

    enum PresenceKeys: String, CodingKey {
        case status
        case appID = "app_id"
        case appDetail = "app_detail"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pid = try container.decode(UInt64.self, forKey: .id)
        id = String(pid)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        friendCode = try container.decodeIfPresent(String.self, forKey: .friendCode)
        nsa = try container.decodeIfPresent(String.self, forKey: .nsa)

        if let presence = try container.decodeIfPresent(
            PresencePayload.self,
            forKey: .presence
        ) {
            onlineStatus = presence.status
            appID = presence.appID
            appDetail = presence.appDetail
        } else {
            onlineStatus = 0
            appID = nil
            appDetail = nil
        }
    }

    private struct PresencePayload: Decodable {
        let status: Int
        let appID: String?
        let appDetail: String?

        enum CodingKeys: String, CodingKey {
            case status
            case appID = "app_id"
            case appDetail = "app_detail"
        }
    }
}

public struct NextendoSession: Codable, Equatable, Sendable {
    public let nexToken: String
    public let user: NextendoUser

    public init(nexToken: String, user: NextendoUser) {
        self.nexToken = nexToken
        self.user = user
    }

    public var accessToken: String { nexToken }
}

public struct NextendoPresence: Codable, Equatable, Sendable {
    public let status: Int
    public let appID: String
    public let appDetail: String
    public let appField: String

    public init(
        status: Int,
        appID: String = "",
        appDetail: String = "",
        appField: String = ""
    ) {
        self.status = status
        self.appID = appID
        self.appDetail = appDetail
        self.appField = appField
    }

    public var online: Bool { status != 0 }
    public var game: String? { appID.isEmpty ? nil : appID }

    enum CodingKeys: String, CodingKey {
        case status
        case appID = "app_id"
        case appDetail = "app_detail"
        case appField = "app_field"
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
