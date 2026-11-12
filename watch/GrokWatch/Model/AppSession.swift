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
    var bubbleStyle = UserDefaults.standard.string(forKey: "bubbleStyle").flatMap(BubbleStyle.init) ?? .ink {
        didSet { UserDefaults.standard.set(bubbleStyle.rawValue, forKey: "bubbleStyle") }
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

    /// The Bots that wait for your answer, each with its open card. Most recent first.
    /// Reads a few recent entries of each candidate, because the Bot list does not carry the card itself.
    func loadWaiting(in roster: Roster) async -> [WaitingBot] {
        let candidates = roster.visible.filter { $0.mayWaitForYou || $0.unread > 0 }.prefix(Self.maxWaitingChecks)
        let found = await withTaskGroup(of: WaitingBot?.self, returning: [WaitingBot].self) { group in
            for entry in candidates {
                group.addTask { [api] in
                    guard let page = try? await api.transcript(of: entry.bot, limit: 15) else { return nil }
                    var messages = page.entries.compactMap { ChatMessage(entry: $0, viewer: entry.bot.viewerName) }.sorted { $0.seq < $1.seq }
                    messages.settleQuestions()
                    return messages.last(where: \.needsAnswer).map { WaitingBot(entry: entry, card: $0) }
                }
            }
            var found: [WaitingBot] = []
            for await bot in group {
                if let bot { found.append(bot) }
            }
            return found
        }
        return found.sorted { ($0.entry.lastActivity ?? .distantPast) > ($1.entry.lastActivity ?? .distantPast) }
    }

    /// Each check is one request, and the list refreshes every 30 seconds.
    private static let maxWaitingChecks = 6

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
    /// Only `Auth` decides that a session is dead: `ConnectClient` already refreshed and retried once on a rejected token.
    func describe(_ error: Error) -> String {
        if case Auth.AuthError.signedOut = error { isSignedIn = false }
        return error.localizedDescription
    }
}
