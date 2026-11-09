import SwiftUI

@main
struct GrokWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isSignedIn { BotListView() } else { LoginView() }
            }
            .environment(session)
            .onOpenURL { session.openBotID = DeepLink.agentID(in: $0) }
        }
        .onChange(of: scenePhase) { if scenePhase == .background { session.scheduleRefresh() } }
        .backgroundTask(.appRefresh(AppSession.refreshID)) { await session.refreshInBackground() }
    }
}
