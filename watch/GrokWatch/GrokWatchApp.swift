import SwiftUI

/// Picks the app to run. A unit-test run hosts the tests in an empty app,
/// so it starts no login poll and makes no network request.
@main
enum GrokWatchMain {
    @MainActor static func main() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
            return
        }
        #endif
        GrokWatchApp.main()
    }
}

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

#if DEBUG
private struct TestHostApp: App {
    var body: some Scene { WindowGroup { EmptyView() } }
}
#endif
