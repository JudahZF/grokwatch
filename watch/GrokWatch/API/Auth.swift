import CryptoKit
import Foundation
import Security

/// Cursor account session for this watch.
/// Refresh tokens rotate, so the watch logs in on its own (never shares the desktop's pair).
actor Auth {
    struct Tokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
    }

    /// A PKCE deep-login attempt: the user opens `url` on another device; the watch polls with `verifier`.
    struct LoginAttempt: Sendable {
        let url: URL
        let uuid: String
        let verifier: String
    }

    enum AuthError: LocalizedError {
        case signedOut
        case http(Int)
        case loginExpired

        var errorDescription: String? {
            switch self {
            case .signedOut: "Signed out"
            case .http(let status): "Auth failed (HTTP \(status))"
            case .loginExpired: "Login timed out"
            }
        }
    }

    /// Prod auth client id, the same one the desktop app uses; used only for token refresh.
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let website = URL(string: "https://cursor.com")!

    nonisolated let machineID: String
    private let tokenStore: any TokenStore
    private let session: URLSession
    private var tokens: Tokens?
    private var refreshing: Task<String, Error>?
    /// Grows on each sign-out, so a refresh that was in flight knows to drop its result.
    private var signOuts = 0

    /// `store` and `session` are seams for tests; the app uses the defaults.
    init(store: any TokenStore = Keychain(), session: URLSession = .shared) {
        tokenStore = store
        self.session = session
        tokens = tokenStore.load()
        machineID = Self.loadMachineID()
    }

    /// Synchronous check for app launch, before any actor hop.
    nonisolated static var hasSavedSession: Bool { Keychain().load() != nil }

    #if DEBUG
    /// Simulator testing without the QR flow:
    /// `SIMCTL_CHILD_GROKWATCH_SEED_TOKENS='{"accessToken":…,"refreshToken":…}' xcrun simctl launch …`
    nonisolated static func seedFromEnvironment() {
        guard let seed = ProcessInfo.processInfo.environment["GROKWATCH_SEED_TOKENS"],
              let tokens = try? JSONDecoder().decode(Tokens.self, from: Data(seed.utf8)) else { return }
        Keychain().save(tokens)
    }
    #endif

    nonisolated static func newLoginAttempt() -> LoginAttempt {
        var random = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        let verifier = Data(random).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let uuid = UUID().uuidString.lowercased()
        var components = URLComponents(url: website.appending(path: "loginDeepControl"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "challenge", value: challenge),
            .init(name: "uuid", value: uuid),
            .init(name: "mode", value: "login"),
            .init(name: "redirectTarget", value: "cli"),
        ]
        return LoginAttempt(url: components.url!, uuid: uuid, verifier: verifier)
    }

    /// Polls until the login finishes on another device. The server answers 404 until then.
    func completeLogin(_ attempt: LoginAttempt) async throws {
        var components = URLComponents(url: ConnectClient.baseURL.appending(path: "auth/poll"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "uuid", value: attempt.uuid), .init(name: "verifier", value: attempt.verifier)]
        for _ in 0..<150 {
            try await Task.sleep(for: .seconds(2))
            let data: Data, status: Int
            do {
                let (body, response) = try await session.data(from: components.url!)
                (data, status) = (body, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch is URLError {
                continue // flaky watch network; keep polling
            }
            if status == 404 { continue }
            guard status == 200 else { throw AuthError.http(status) }
            store(try JSONDecoder().decode(Tokens.self, from: data))
            return
        }
        throw AuthError.loginExpired
    }

    /// A valid access token, refreshed (single flight) within 5 minutes of expiry.
    func accessToken() async throws -> String {
        guard let tokens else { throw AuthError.signedOut }
        if let expiry = Self.expiry(of: tokens.accessToken), expiry.timeIntervalSinceNow > 300 {
            return tokens.accessToken
        }
        return try await refreshOnce()
    }

    /// A new access token after the server rejected `rejected`.
    /// When another call already replaced that token, returns the stored one without a new refresh.
    func accessToken(replacing rejected: String) async throws -> String {
        guard let tokens else { throw AuthError.signedOut }
        guard tokens.accessToken == rejected else { return tokens.accessToken }
        return try await refreshOnce()
    }

    func signOut() {
        signOuts += 1
        tokens = nil
        tokenStore.clear()
    }

    /// Joins the refresh in flight or starts one. Refresh tokens rotate, so two refreshes with one token would end the session.
    private func refreshOnce() async throws -> String {
        if let refreshing { return try await refreshing.value }
        guard let tokens else { throw AuthError.signedOut }
        let task = Task { try await refresh(using: tokens.refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh(using refreshToken: String) async throws -> String {
        struct Body: Encodable {
            let client_id: String
            let grant_type = "refresh_token"
            let refresh_token: String
        }
        struct Reply: Decodable {
            let access_token: String?
            let refresh_token: String?
            let shouldLogout: Bool?
        }
        var request = URLRequest(url: ConnectClient.baseURL.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(Body(client_id: Self.clientID, refresh_token: refreshToken))
        let signOutsBefore = signOuts
        let (data, response) = try await session.data(for: request)
        // A sign-out while the request was out wins: storing the new pair would sign the user back in.
        guard signOuts == signOutsBefore else { throw AuthError.signedOut }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if reply?.shouldLogout == true || status == 401 || status == 403 {
            signOut()
            throw AuthError.signedOut
        }
        guard status == 200, let access = reply?.access_token, !access.isEmpty else { throw AuthError.http(status) }
        store(Tokens(accessToken: access, refreshToken: reply?.refresh_token ?? refreshToken))
        return access
    }

    private func store(_ new: Tokens) {
        tokens = new
        tokenStore.save(new)
    }

    private static func expiry(of jwt: String) -> Date? {
        struct Claims: Decodable { let exp: TimeInterval }
        let parts = jwt.split(separator: ".")
        guard parts.count > 1, let payload = Data(base64URLEncoded: String(parts[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload) else { return nil }
        return Date(timeIntervalSince1970: claims.exp)
    }

    /// Stable per-install id in the sha256-hex shape the desktop uses.
    private static func loadMachineID() -> String {
        let key = "machineID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

/// Where `Auth` keeps the token pair: the Keychain in the app, memory in tests.
protocol TokenStore: Sendable {
    func load() -> Auth.Tokens?
    func save(_ tokens: Auth.Tokens)
    func clear()
}

/// One Keychain item holding the token pair as JSON.
struct Keychain: TokenStore {
    private var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            // The bundle id, so each signing identity keeps its own item.
            kSecAttrService: Bundle.main.bundleIdentifier ?? "grokwatch",
            kSecAttrAccount: "cursor-tokens",
        ]
    }

    func load() -> Auth.Tokens? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData: true]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Auth.Tokens.self, from: data)
    }

    /// Updates the item in place, so a failed write never leaves the watch without its pair.
    func save(_ tokens: Auth.Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
