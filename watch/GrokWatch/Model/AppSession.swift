import Foundation
import Observation
import WatchKit
import WidgetKit

/// App-wide state: auth, API, audio, and settings.
@MainActor @Observable
final class AppSession {
    let auth: Auth
    let api: GrokBotAPI
    let speaker = Speaker()
    var isSignedIn: Bool
    var autoSpeak = UserDefaults.standard.bool(forKey: "autoSpeak") {
        didSet { UserDefaults.standard.set(autoSpeak, forKey: "autoSpeak") }
    }
    /// True during a voice call; chat auto-speak stays quiet so it does not talk over the call.
    var isInCall = false
    /// A Bot to open, from a complication tap (`DeepLink`). The Bot list consumes it.
    var openBotID: String?

    init() {
        #if DEBUG
        Auth.seedFromEnvironment()
        #endif
        isSignedIn = Auth.hasSavedSession
        let auth = Auth()
        self.auth = auth
        api = GrokBotAPI(connect: ConnectClient(auth: auth))
    }

    func signOut() {
        speaker.stop()
        isSignedIn = false
        Glance.clear()
        WidgetCenter.shared.reloadAllTimelines()
        Task { await auth.signOut() }
    }

    /// The Bot list, ordered as on the phone. Also updates the complication.
    func loadRoster() async throws -> Roster {
        let bots = try await api.bots()
        async let statuses = api.statuses(of: bots)
        async let settings = api.runtimeSettings()
        let roster = Roster(bots: bots, statuses: try await statuses, settings: try await settings)
        if roster.glance.save() { WidgetCenter.shared.reloadAllTimelines() }
        return roster
    }

    /// Background app refresh keeps the complication current. watchOS decides the real timing (a few times an hour at most).
    func scheduleRefresh() {
        guard isSignedIn else { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: .now + 20 * 60, userInfo: Self.refreshID as NSString
        ) { _ in }
    }

    func refreshInBackground() async {
        _ = try? await loadRoster()
        scheduleRefresh()
    }

    static let refreshID = "glance"

    /// User-facing text for an error. A dead session sends the user back to login.
    func describe(_ error: Error) -> String {
        if case Auth.AuthError.signedOut = error { isSignedIn = false }
        if let rpc = error as? ConnectClient.RPCError, rpc.code == "unauthenticated" { signOut() }
        return error.localizedDescription
    }
}
