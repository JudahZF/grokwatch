import Foundation
import Testing
@testable import GrokWatch

/// The Bot list must match the official apps: hidden Bots apart, pinned Bots in pin order, recent first.
struct RosterTests {
    private func bot(_ id: String, updatedAtMs: Int64 = 0) -> Bot {
        var bot = Bot()
        bot.agentID = id
        bot.updatedAtMs = updatedAtMs
        return bot
    }

    private func status(
        _ id: String, lastActivityAtMs: Int64 = 0, unread: UInt32 = 0, unreadThreads: UInt32 = 0, hidden: Bool = false
    ) -> (String, Aiserver_V1_GrokBotAgentStatus) {
        var status = Aiserver_V1_GrokBotAgentStatus()
        status.agentID = id
        status.client.lastActivityAtMs = lastActivityAtMs
        status.client.unreadCount = unread
        status.client.unreadThreadCount = unreadThreads
        status.client.hiddenFromSidebar = hidden
        return (id, status)
    }

    private func settings(pinned: [String] = [], sections: [Aiserver_V1_GrokBotSidebarSection] = [])
        -> Aiserver_V1_GrokBotUserRuntimeSettings
    {
        var settings = Aiserver_V1_GrokBotUserRuntimeSettings()
        settings.pinnedAgents.agentIds = pinned
        settings.sidebarSections.sections = sections
        return settings
    }

    private func ids(_ sections: [Roster.Section]) -> [[String]] { sections.map { $0.entries.map(\.id) } }

    @Test func hiddenBotsLeaveTheList() {
        let roster = Roster(
            bots: [bot("a"), bot("b")],
            statuses: Dictionary(uniqueKeysWithValues: [status("a", hidden: true)]),
            settings: settings()
        )
        #expect(roster.hidden.map(\.id) == ["a"])
        #expect(ids(roster.sections) == [["b"]])
    }

    @Test func pinnedBotsComeInPinOrderOnce() {
        let roster = Roster(
            bots: [bot("a", updatedAtMs: 4), bot("b", updatedAtMs: 3), bot("c", updatedAtMs: 2), bot("d", updatedAtMs: 1)],
            statuses: [:],
            settings: settings(pinned: ["c", "a"])
        )
        #expect(roster.pinned.map(\.id) == ["c", "a"])
        #expect(roster.pinned.allSatisfy { $0.isPinned })
        #expect(ids(roster.sections) == [["b", "d"]])
    }

    /// Recency is the later of the Bot's `updatedAtMs` and its client `lastActivityAtMs`.
    @Test func mostRecentActivityFirst() {
        let roster = Roster(
            bots: [bot("a", updatedAtMs: 100), bot("b", updatedAtMs: 50), bot("c", updatedAtMs: 150)],
            statuses: Dictionary(uniqueKeysWithValues: [status("b", lastActivityAtMs: 200)]),
            settings: settings()
        )
        #expect(ids(roster.sections) == [["b", "c", "a"]])
        #expect(roster.sections.first?.entries.first?.lastActivity == Date(timeIntervalSince1970: 0.2))
    }

    /// Custom sections come in their order, recent first inside each; the rest go to a trailing "Bots" section.
    @Test func customSectionsThenRest() {
        var work = Aiserver_V1_GrokBotSidebarSection()
        work.id = "work"
        work.name = "Work"
        work.agentIds = ["a", "c"]
        let roster = Roster(
            bots: [bot("a", updatedAtMs: 1), bot("b", updatedAtMs: 2), bot("c", updatedAtMs: 3)],
            statuses: [:],
            settings: settings(sections: [work])
        )
        #expect(roster.sections.map(\.title) == ["Work", "Bots"])
        #expect(ids(roster.sections) == [["c", "a"], ["b"]])
    }

    @Test func unreadAddsMessagesAndThreads() {
        let roster = Roster(
            bots: [bot("a")],
            statuses: Dictionary(uniqueKeysWithValues: [status("a", unread: 2, unreadThreads: 3)]),
            settings: settings()
        )
        #expect(roster.sections.first?.entries.first?.unread == 5)
    }
}
