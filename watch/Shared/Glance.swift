import Foundation

/// What the complication shows. The app writes it after each Bot list refresh; the widget only reads it,
/// so the widget never needs tokens (refresh tokens rotate, and two refreshers would sign each other out).
struct Glance: Codable, Equatable {
    struct UnreadBot: Codable, Equatable {
        let agentID: String
        let name: String
        let unread: UInt32
    }

    var unreadBots: [UnreadBot]
    var runningCount: Int

    var totalUnread: UInt32 { unreadBots.reduce(0) { $0 + $1.unread } }

    /// From Info.plist (`AppGroupID`, set by Signing.xcconfig), so the app and the widget always name the same store.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    private static let key = "glance"
    private static var defaults: UserDefaults? { appGroup.flatMap(UserDefaults.init(suiteName:)) }

    static func load() -> Glance? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Glance.self, from: $0) }
    }

    /// Returns true when the stored value changed (so the caller reloads the widget only then).
    @discardableResult
    func save() -> Bool {
        guard self != Self.load(), let data = try? JSONEncoder().encode(self) else { return false }
        Self.defaults?.set(data, forKey: Self.key)
        return true
    }

    static func clear() { defaults?.removeObject(forKey: key) }
}

/// `grokwatch://bot/<agentID>` opens that Bot's chat.
enum DeepLink {
    static let scheme = "grokwatch"

    static func bot(_ agentID: String) -> URL { URL(string: "\(scheme)://bot/\(agentID)")! }

    static func agentID(in url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "bot" else { return nil }
        return url.pathComponents.dropFirst().first
    }
}
