import SwiftUI

private enum Route: Hashable {
    case chat(Bot)
    case hidden
}

struct BotListView: View {
    @Environment(AppSession.self) private var session
    @State private var roster: Roster?
    @State private var path: [Route] = []
    @State private var problem: String?

    var body: some View {
        @Bindable var session = session
        NavigationStack(path: $path) {
            List {
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
                ForEach(roster?.sections ?? []) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            NavigationLink(value: Route.chat(entry.bot)) { BotRow(entry: entry) }
                                .botActions(entry, roster: roster, reload: load)
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
                Section {
                    if let hidden = roster?.hidden, !hidden.isEmpty {
                        NavigationLink(value: Route.hidden) {
                            Label("Hidden (\(hidden.count))", systemImage: "eye.slash")
                        }
                    }
                    Toggle("Read replies aloud", isOn: $session.autoSpeak)
                    Button("Sign out", role: .destructive) { session.signOut() }
                }
            }
            .navigationTitle("Bots")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chat(let bot): ChatView(bot: bot, session: session)
                case .hidden: HiddenBotsView(roster: roster, reload: load)
                }
            }
            .overlay { if roster == nil && problem == nil { ProgressView() } }
            .onChange(of: session.openBotID) { openRequestedBot() }
            // Refresh while the list is on screen, so unread dots and order follow other devices.
            .task(id: path.isEmpty) {
                guard path.isEmpty else { return }
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    private func load() async {
        do {
            roster = try await session.loadRoster()
            problem = nil
            openRequestedBot()
        } catch is CancellationError {
        } catch {
            problem = session.describe(error)
        }
    }

    /// Opens the Bot a complication tap asked for, once the list knows it.
    private func openRequestedBot() {
        if let id = session.openBotID, let entry = roster?.entry(for: id) {
            session.openBotID = nil
            path = [.chat(entry.bot)]
        }
        #if DEBUG
        // Simulator testing: SIMCTL_CHILD_GROKWATCH_OPEN_BOT=<name prefix> opens that chat on launch.
        if path.isEmpty, let name = ProcessInfo.processInfo.environment["GROKWATCH_OPEN_BOT"]?.lowercased(),
           let entry = roster.map({ $0.sections.flatMap(\.entries) + $0.hidden })?.first(where: { $0.bot.name.lowercased().hasPrefix(name) }) {
            path = [.chat(entry.bot)]
        }
        #endif
    }
}

private struct HiddenBotsView: View {
    let roster: Roster?
    let reload: () async -> Void

    var body: some View {
        List(roster?.hidden ?? []) { entry in
            NavigationLink(value: Route.chat(entry.bot)) { BotRow(entry: entry) }
                .botActions(entry, roster: roster, reload: reload)
        }
        .navigationTitle("Hidden")
    }
}

/// Swipe actions, as on the phone. Changes sync to every device through the account.
private struct BotActions: ViewModifier {
    @Environment(AppSession.self) private var session
    let entry: Roster.Entry
    let roster: Roster?
    let reload: () async -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) {
                Button { run { api in
                    let pinned = roster?.pinnedIDs ?? []
                    try await api.setPinned(entry.isPinned ? pinned.filter { $0 != entry.id } : pinned + [entry.id])
                } } label: {
                    Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
                Button { run { api in
                    try await api.setClientState(of: entry.bot, entry.unread > 0 ? \.markRead : \.markUnread, to: true)
                } } label: {
                    Label(entry.unread > 0 ? "Read" : "Unread", systemImage: entry.unread > 0 ? "envelope.open" : "envelope.badge")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing) {
                Button { run { api in
                    try await api.setClientState(of: entry.bot, \.hiddenFromSidebar, to: !entry.isHidden)
                } } label: {
                    Label(entry.isHidden ? "Show" : "Hide", systemImage: entry.isHidden ? "eye" : "eye.slash")
                }
                .tint(.gray)
                Button { run { api in
                    try await api.setClientState(of: entry.bot, \.notificationsEnabled, to: entry.isMuted)
                } } label: {
                    Label(entry.isMuted ? "Unmute" : "Mute", systemImage: entry.isMuted ? "bell" : "bell.slash")
                }
                .tint(.indigo)
            }
    }

    private func run(_ change: @escaping @Sendable (GrokBotAPI) async throws -> Void) {
        Task {
            do {
                try await change(session.api)
            } catch {
                _ = session.describe(error)
            }
            await reload()
        }
    }
}

extension View {
    fileprivate func botActions(_ entry: Roster.Entry, roster: Roster?, reload: @escaping () async -> Void) -> some View {
        modifier(BotActions(entry: entry, roster: roster, reload: reload))
    }
}

private struct BotRow: View {
    let entry: Roster.Entry

    var body: some View {
        let parts = entry.bot.displayParts
        let isUnread = entry.unread > 0
        HStack(alignment: .top, spacing: 8) {
            AsyncImage(url: URL(string: entry.bot.avatarURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Text(parts.name.prefix(1)).font(.headline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.tint.opacity(0.4))
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                if entry.isRunning {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        .background(.black, in: Circle())
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(parts.name).lineLimit(1).fontWeight(isUnread ? .semibold : .regular)
                    if entry.isMuted { Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if let date = entry.lastActivity {
                        Text(Self.shortTime(date)).font(.caption2).foregroundStyle(isUnread ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                }
                HStack(alignment: .top, spacing: 4) {
                    Text(entry.preview ?? parts.role ?? " ")
                        .font(.caption2)
                        .foregroundStyle(isUnread ? .primary : .secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if isUnread {
                        Text("\(entry.unread)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .background(.tint, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// "14:05" today, "Tue" this week, "12 Oct" before that.
    private static func shortTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

extension Bot {
    /// Bot names follow "Name · Role" (e.g. "Raven · Research").
    var displayParts: (name: String, role: String?) {
        let parts = name.components(separatedBy: " · ")
        return (parts[0], parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil)
    }
}
