import SwiftUI

enum Route: Hashable {
    case chat(Bot)
    case settings
    case hidden
}

/// Home. Bots that wait for you come first, because triage is the main job of a watch.
/// Below that it follows the phone: pinned Bots as a row of large avatars, then a flat list.
struct BotListView: View {
    @Environment(AppSession.self) private var session
    @State private var roster: Roster?
    @State private var waiting: [WaitingBot] = []
    @State private var path: [Route] = []
    @State private var problem: String?
    @State private var actionsFor: Roster.Entry?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Theme.danger).listRowBackground(Color.clear)
                }
                if !waiting.isEmpty {
                    Section("Waiting for you") {
                        ForEach(waiting) { bot in
                            WaitingCard(waiting: bot, open: { path.append(.chat(bot.entry.bot)) }, reload: load)
                                .listRowBackground(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
                        }
                    }
                }
                if let pinned = roster?.pinned, !pinned.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 8) {
                        ForEach(pinned) { entry in
                            PinnedBot(entry: entry)
                                .onTapGesture { path.append(.chat(entry.bot)) }
                                .onLongPressGesture { actionsFor = entry }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                ForEach(roster?.sections ?? []) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            NavigationLink(value: Route.chat(entry.bot)) { BotRow(entry: entry) }
                                .botSwipeActions(entry, roster: roster, reload: load)
                                .flatRow()
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chat(let bot): ChatView(bot: bot, session: session)
                case .settings: SettingsView(hiddenCount: roster?.hidden.count ?? 0)
                case .hidden: HiddenBotsView(roster: roster, reload: load)
                }
            }
            .confirmationDialog(actionsFor?.bot.displayParts.name ?? "", isPresented: isShowingActions, presenting: actionsFor) { entry in
                ForEach(BotAction.allCases, id: \.self) { action in
                    Button(action.title(for: entry)) { action.run(on: entry, roster: roster, session: session, reload: load) }
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

    private var isShowingActions: Binding<Bool> {
        Binding { actionsFor != nil } set: { if !$0 { actionsFor = nil } }
    }

    private func load() async {
        do {
            let roster = try await session.loadRoster()
            self.roster = roster
            problem = nil
            openRequestedBot()
            let waiting = await session.loadWaiting(in: roster)
            if !Task.isCancelled { self.waiting = waiting }
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
           let entry = roster.map({ $0.visible + $0.hidden })?.first(where: { $0.bot.name.lowercased().hasPrefix(name) }) {
            path = [.chat(entry.bot)]
        }
        #endif
    }
}

struct HiddenBotsView: View {
    let roster: Roster?
    let reload: () async -> Void

    var body: some View {
        List(roster?.hidden ?? []) { entry in
            NavigationLink(value: Route.chat(entry.bot)) { BotRow(entry: entry) }
                .botSwipeActions(entry, roster: roster, reload: reload)
                .flatRow()
        }
        .navigationTitle("Hidden")
    }
}

/// What you can do to a Bot from the list. Changes sync to every device through the account.
private enum BotAction: CaseIterable {
    case pin, read, mute, hide

    func title(for entry: Roster.Entry) -> String {
        switch self {
        case .pin: entry.isPinned ? "Unpin" : "Pin"
        case .read: entry.unread > 0 ? "Mark read" : "Mark unread"
        case .mute: entry.isMuted ? "Unmute" : "Mute"
        case .hide: entry.isHidden ? "Show" : "Hide"
        }
    }

    func icon(for entry: Roster.Entry) -> String {
        switch self {
        case .pin: entry.isPinned ? "pin.slash" : "pin"
        case .read: entry.unread > 0 ? "envelope.open" : "envelope.badge"
        case .mute: entry.isMuted ? "bell" : "bell.slash"
        case .hide: entry.isHidden ? "eye" : "eye.slash"
        }
    }

    var tint: Color {
        switch self {
        case .pin: .orange
        case .read: .blue
        case .mute: .indigo
        case .hide: .gray
        }
    }

    @MainActor
    func run(on entry: Roster.Entry, roster: Roster?, session: AppSession, reload: @escaping () async -> Void) {
        let pinned = roster?.pinnedIDs ?? []
        Task {
            do {
                switch self {
                case .pin: try await session.api.setPinned(entry.isPinned ? pinned.filter { $0 != entry.id } : pinned + [entry.id])
                case .read: try await session.api.setClientState(of: entry.bot, entry.unread > 0 ? \.markRead : \.markUnread, to: true)
                case .mute: try await session.api.setClientState(of: entry.bot, \.notificationsEnabled, to: entry.isMuted)
                case .hide: try await session.api.setClientState(of: entry.bot, \.hiddenFromSidebar, to: !entry.isHidden)
                }
            } catch {
                _ = session.describe(error)
            }
            await reload()
        }
    }
}

/// Swipe right to pin or mark read; swipe left to hide or mute. Pinned Bots have no row, so they use a long press.
private struct BotSwipeActions: ViewModifier {
    @Environment(AppSession.self) private var session
    let entry: Roster.Entry
    let roster: Roster?
    let reload: () async -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) { buttons(for: [.pin, .read]) }
            .swipeActions(edge: .trailing) { buttons(for: [.hide, .mute]) }
    }

    private func buttons(for actions: [BotAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            Button { action.run(on: entry, roster: roster, session: session, reload: reload) } label: {
                Label(action.title(for: entry), systemImage: action.icon(for: entry))
            }
            .tint(action.tint)
        }
    }
}

extension View {
    fileprivate func botSwipeActions(_ entry: Roster.Entry, roster: Roster?, reload: @escaping () async -> Void) -> some View {
        modifier(BotSwipeActions(entry: entry, roster: roster, reload: reload))
    }

    /// A list row with no platter, as in the official apps.
    fileprivate func flatRow() -> some View {
        listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2))
    }
}

/// A Bot's open card on the Bot list, with its answers. A tap outside the buttons opens the chat.
private struct WaitingCard: View {
    @Environment(AppSession.self) private var session
    let waiting: WaitingBot
    let open: () -> Void
    let reload: () async -> Void
    @State private var isBusy = false
    @State private var problem: String?

    /// Up to this many question answers fit on the card; a longer question opens the chat.
    private static let maxOptions = 3
    /// A longer approval command opens the chat; see `quickApproval`.
    private static let maxCommandLength = 80
    /// A longer approval summary opens the chat; see `quickApproval`.
    private static let maxSummaryLength = 100

    private var bot: Bot { waiting.entry.bot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    BotAvatar(bot: bot).frame(width: 22, height: 22)
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(Theme.attention).frame(width: 7, height: 7).offset(x: 2, y: -2)
                        }
                    Text(bot.displayParts.name).font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let date = waiting.entry.lastActivity {
                        Text(date.listStamp).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // Never cut when Allow and Deny show: you answer only what you read in full.
                Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(quickApproval == nil ? 3 : nil)
                if case .approval(let approval) = waiting.card.content, let command = approval.command, isReadable(command) {
                    Text(command).font(.caption2.monospaced())
                }
                if let problem { Text(problem).font(.caption2).foregroundStyle(Theme.danger) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)

            if isBusy {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                answers
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        switch waiting.card.content {
        case .question(let question): question.prompt
        case .approval(let approval): approval.summary
        case .draft(let draft): draft.heading
        case .form(let form): form.title
        default: waiting.entry.preview ?? ""
        }
    }

    /// The approval, when the card shows all of it: a short summary, no reason, and a readable command (if any).
    /// Only then does the card offer Allow and Deny; any other approval opens the chat, which shows it in full.
    private var quickApproval: Approval? {
        guard case .approval(let approval) = waiting.card.content,
              approval.summary.count <= Self.maxSummaryLength,
              approval.reason?.isEmpty ?? true,
              approval.command.map(isReadable) ?? true
        else { return nil }
        return approval
    }

    @ViewBuilder private var answers: some View {
        if let approval = quickApproval {
            HStack(spacing: 4) {
                Button("Deny") { answer { try await $0.resolveApproval(approval.requestID, of: bot, as: .denied) } }
                    .buttonStyle(.pill)
                Button("Allow") { answer { try await $0.resolveApproval(approval.requestID, of: bot, as: .approved) } }
                    .buttonStyle(.primaryPill)
            }
        } else if case .question(let question) = waiting.card.content, question.options.count <= Self.maxOptions {
            ForEach(question.options, id: \.self) { option in
                Button(option.label) { answer { try await $0.answer(waiting.card.entryID, of: bot, with: option.value) } }
                    .buttonStyle(.pill)
            }
        } else {
            Button("Open", action: open).buttonStyle(.primaryPill)
        }
    }

    private func isReadable(_ command: String) -> Bool { command.count <= Self.maxCommandLength }

    private func answer(_ send: @escaping @Sendable (GrokBotAPI) async throws -> Void) {
        isBusy = true
        problem = nil
        Task {
            do {
                try await send(session.api)
                await reload()
            } catch {
                problem = session.describe(error)
            }
            isBusy = false
        }
    }
}

/// A pinned Bot: a large avatar with its name below, as on the phone.
private struct PinnedBot: View {
    let entry: Roster.Entry

    var body: some View {
        VStack(spacing: 2) {
            BotAvatar(bot: entry.bot)
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottomTrailing) {
                    if entry.isRunning {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14).background(.black, in: Circle())
                    } else if entry.isMain {
                        Image(systemName: "star.fill").font(.system(size: 8, weight: .bold))
                            .frame(width: 15, height: 15)
                            .background(Theme.attention, in: Circle())
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if entry.unread > 0 { UnreadBadge(count: entry.unread).offset(x: 4, y: -2) }
                }
            Text(entry.bot.displayParts.name).font(.caption2).lineLimit(1)
                .foregroundStyle(entry.unread > 0 ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct UnreadBadge: View {
    let count: UInt32

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .background(Theme.unread, in: Capsule())
            .accessibilityLabel("\(count) unread")
    }
}

private struct BotRow: View {
    let entry: Roster.Entry

    var body: some View {
        let parts = entry.bot.displayParts
        let isUnread = entry.unread > 0
        HStack(alignment: .top, spacing: 8) {
            BotAvatar(bot: entry.bot)
                .frame(width: 32, height: 32)
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
                        Text(date.listStamp).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 4) {
                    Text(entry.preview ?? parts.role ?? " ")
                        .font(.caption2)
                        .foregroundStyle(isUnread ? .primary : .secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if isUnread { UnreadBadge(count: entry.unread) }
                }
            }
        }
    }
}

extension Date {
    /// "14:05" today, "Tue" this week, "12 Oct" before that.
    fileprivate var listStamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

extension Bot {
    /// Bot names follow "Name · Role" (e.g. "Raven · Research").
    var displayParts: (name: String, role: String?) {
        let parts = name.components(separatedBy: " · ")
        return (parts[0], parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil)
    }
}
