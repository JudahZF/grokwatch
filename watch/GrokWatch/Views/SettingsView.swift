import SwiftUI

struct SettingsView: View {
    @Environment(AppSession.self) private var session
    let hiddenCount: Int
    @State private var isConfirmingSignOut = false

    var body: some View {
        @Bindable var session = session
        List {
            Picker("My bubbles", selection: $session.bubbleStyle) {
                ForEach(BubbleStyle.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Read replies aloud", isOn: $session.autoSpeak)
            if hiddenCount > 0 {
                NavigationLink(value: Route.hidden) { Label("Hidden (\(hiddenCount))", systemImage: "eye.slash") }
            }
            Button("Sign out", role: .destructive) { isConfirmingSignOut = true }
        }
        .navigationTitle("Settings")
        // A new login needs the phone, so one stray tap must not sign you out.
        .confirmationDialog("Sign out?", isPresented: $isConfirmingSignOut) {
            Button("Sign out", role: .destructive) { session.signOut() }
        } message: {
            Text("You need your phone to sign in again.")
        }
    }
}
