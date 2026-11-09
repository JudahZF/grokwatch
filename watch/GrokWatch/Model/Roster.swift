import Foundation

/// The Bot list as the official apps show it.
/// - Hidden: Bots with `hidden_from_sidebar` move to a separate list (shared Bots that are hidden are dropped).
/// - Order: pinned Bots in pin order, then custom sections; inside a group, most recent activity first.
/// - Unread: `unread_count` or `unread_thread_count` above zero.
struct Roster {
    struct Entry: Identifiable, Hashable {
        let bot: Bot
        let unread: UInt32
        let isRunning: Bool
        let isPinned: Bool
        let isHidden: Bool
        let isMuted: Bool
        /// The last message, as the server summarises it for the sidebar.
        let preview: String?
        let lastActivity: Date?
        var id: String { bot.agentID }
    }

    struct Section: Identifiable {
        let id: String
        let title: String?
        let entries: [Entry]
    }

    var sections: [Section] = []
    var hidden: [Entry] = []
    /// Pinned Bot ids in pin order, for pin and unpin.
    var pinnedIDs: [String] = []

    /// Section id the desktop uses for "every Bot not in another section".
    private static let restSectionID = "__agents__"

    init() {}

    init(bots: [Bot], statuses: [String: Aiserver_V1_GrokBotAgentStatus], settings: Aiserver_V1_GrokBotUserRuntimeSettings) {
        func recency(_ bot: Bot) -> Int64 { max(bot.updatedAtMs, statuses[bot.agentID]?.client.lastActivityAtMs ?? 0) }
        let pinnedIDs = settings.pinnedAgents.agentIds
        func entry(_ bot: Bot) -> Entry {
            let status = statuses[bot.agentID]
            let client = status.flatMap { $0.hasClient ? $0.client : nil }
            return Entry(
                bot: bot,
                unread: (client?.unreadCount ?? 0) + (client?.unreadThreadCount ?? 0),
                isRunning: status?.isRunning ?? false,
                isPinned: pinnedIDs.contains(bot.agentID),
                isHidden: client?.hiddenFromSidebar ?? false,
                isMuted: client.map { !$0.notificationsEnabled } ?? false,
                preview: client.flatMap(Self.preview),
                lastActivity: recency(bot) > 0 ? Date(timeIntervalSince1970: Double(recency(bot)) / 1000) : nil
            )
        }
        func isHidden(_ bot: Bot) -> Bool {
            let isSharedTeamDefault = bot.hasViewerIsOwner && !bot.viewerIsOwner && bot.teamDefaultForViewer
            return statuses[bot.agentID]?.client.hiddenFromSidebar == true && !isSharedTeamDefault
        }

        let byRecency = bots.sorted { recency($0) > recency($1) }
        let isOwned = { (bot: Bot) in !bot.hasViewerIsOwner || bot.viewerIsOwner }
        hidden = byRecency.filter { isHidden($0) && isOwned($0) }.map(entry)
        let visible = byRecency.filter { !isHidden($0) }
        let visibleByID = Dictionary(visible.map { ($0.agentID, $0) }) { first, _ in first }

        self.pinnedIDs = pinnedIDs
        let pinned = pinnedIDs.compactMap { visibleByID[$0] }
        let unpinned = visible.filter { !pinnedIDs.contains($0.agentID) }

        var groups: [Section] = []
        if !pinned.isEmpty { groups.append(Section(id: "pinned", title: "Pinned", entries: pinned.map(entry))) }

        let custom = settings.sidebarSections.sections
        if custom.isEmpty {
            groups.append(Section(id: Self.restSectionID, title: pinned.isEmpty ? nil : "Bots", entries: unpinned.map(entry)))
        } else {
            var sectionOf: [String: String] = [:]
            for section in custom where section.id != Self.restSectionID {
                for id in section.agentIds { sectionOf[id] = section.id }
            }
            var layout = custom
            if !layout.contains(where: { $0.id == Self.restSectionID }) {
                var rest = Aiserver_V1_GrokBotSidebarSection()
                rest.id = Self.restSectionID
                rest.name = "Bots"
                layout.append(rest)
            }
            for section in layout {
                let members = unpinned.filter {
                    section.id == Self.restSectionID ? sectionOf[$0.agentID] == nil : sectionOf[$0.agentID] == section.id
                }
                guard !members.isEmpty else { continue }
                groups.append(Section(id: section.id, title: section.name.isEmpty ? "Bots" : section.name, entries: members.map(entry)))
            }
        }
        sections = groups
    }

    private static func preview(_ client: Aiserver_V1_GrokBotAgentClientState) -> String? {
        let text: String? = switch client.lastEntryPreview.preview {
        case .text(let text): text.text
        case .sentAgentMessage(let message), .receivedAgentMessage(let message): "\(message.peerName): \(message.text)"
        case .attachments(let attachments): attachments.count == 1 ? "Attachment" : "\(attachments.count) attachments"
        case .link(let link): link.url
        case .widgetPrompt(let widget): widget.prompt
        case .widgetAnswered(let widget): widget.answer
        case .widgetOptions(let widget): widget.prompt
        case nil: client.hasLastMessagePreview ? client.lastMessagePreview : nil
        }
        return text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension Roster {
    func entry(for agentID: String) -> Entry? {
        (sections.flatMap(\.entries) + hidden).first { $0.id == agentID }
    }

    /// Complication data: visible Bots with unread messages. Muted Bots are left out, as they are for notifications.
    var glance: Glance {
        let visible = sections.flatMap(\.entries)
        return Glance(
            unreadBots: visible.filter { $0.unread > 0 && !$0.isMuted }
                .map { Glance.UnreadBot(agentID: $0.id, name: $0.bot.displayParts.name, unread: $0.unread) },
            runningCount: visible.filter(\.isRunning).count
        )
    }
}
