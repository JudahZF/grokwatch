#if DEBUG
import Foundation
import SwiftProtobuf

/// Demo mode: a made-up account, for screenshots and for a look at the app without a login.
/// `SIMCTL_CHILD_GROKWATCH_DEMO=1 xcrun simctl launch <sim-id> <bundle-id>`
/// `load` answers the calls that fill the Bot list and the chats. Every other call fails with a notice.
/// No request leaves the watch, and the Keychain is not read or written.
enum Demo {
    static var isOn: Bool { ProcessInfo.processInfo.environment["GROKWATCH_DEMO"] != nil }

    /// A token pair that never needs a refresh.
    struct Store: TokenStore {
        func load() -> Auth.Tokens? {
            let claims = Data(#"{"exp":4102444800}"#.utf8).base64URLEncodedString()
            return Auth.Tokens(accessToken: "demo.\(claims).demo", refreshToken: "demo")
        }
        func save(_ tokens: Auth.Tokens) {}
        func clear() {}
    }

    static let load: HTTPLoader = { request in
        let url = request.url ?? ConnectClient.baseURL
        func response(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) ?? URLResponse()
        }
        // The login poll: "not yet", for as long as the login screen shows.
        if url.lastPathComponent == "poll" { return (Data(), response(404)) }
        guard let reply = reply(to: url.lastPathComponent, body: request.httpBody ?? Data()) else {
            return (Data(#"{"code":"unavailable","message":"Demo mode shows sample data only."}"#.utf8), response(400))
        }
        return (try reply.serializedData(), response(200))
    }

    private static func reply(to method: String, body: Data) -> (any Message)? {
        switch method {
        case "ListGrokBotAgents":
            var reply = Aiserver_V1_ListGrokBotAgentsResponse()
            reply.agents = samples.map(\.bot)
            return reply
        case "ListGrokBotAgentStatuses":
            var reply = Aiserver_V1_ListGrokBotAgentStatusesResponse()
            reply.statuses = samples.map(\.status)
            return reply
        case "GetGrokBotUserRuntimeSettings":
            var reply = Aiserver_V1_GetGrokBotUserRuntimeSettingsResponse()
            reply.settings.pinnedAgents.agentIds = ["demo-atlas", "demo-juno", "demo-pixel"]
            reply.settings.mainAgentID = "demo-atlas"
            return reply
        case "ListGrokBotTranscriptEntries":
            guard let request = try? Aiserver_V1_ListGrokBotTranscriptEntriesRequest(serializedBytes: body) else { return nil }
            var reply = Aiserver_V1_ListGrokBotTranscriptEntriesResponse()
            reply.generation = 1
            // The newest page holds the whole chat, so a request for earlier entries gets none.
            if request.beforeSeq == 0 { reply.entries = samples.first { $0.bot.agentID == request.agentID }?.entries ?? [] }
            return reply
        default:
            return nil
        }
    }

    // MARK: Sample data

    private struct Sample: Sendable {
        let bot: Bot
        let status: Aiserver_V1_GrokBotAgentStatus
        let entries: [TranscriptEntry]
    }

    /// One transcript entry: its kind and its JSON body, in the shapes `ChatMessage` reads.
    private typealias Row = (kind: String, body: [String: Any])

    private static func me(_ text: String) -> Row {
        ("message", ["role": "user", "content": text, "clientNonce": UUID().uuidString.lowercased()])
    }

    /// A Bot message of `type`: `text`, or a card (`widget`, `auto-review-approval`, `email-draft`).
    private static func bot(_ type: String, _ payload: [String: Any]) -> Row {
        ("send-message", ["message": payload.merging(["type": type]) { $1 }])
    }

    private static let samples: [Sample] = [
        sample("Atlas · Chief of staff", shape: "blob", color: .blue, minutesAgo: 18, preview: "Your 10:00 with Priya moved to 10:30.", chat: [
            me("Anything urgent this morning?"),
            bot("text", ["content": "Two things. The Q3 report is ready for your review."]),
            bot("text", ["content": "Your 10:00 with Priya moved to 10:30."]),
        ]),
        sample("Juno · Inbox", shape: "pebble", color: .green, minutesAgo: 25, preview: "Draft: Re: Friday review", chat: [
            bot("text", ["content": "Sam asked if Friday still works for the review. I wrote a reply."]),
            bot("email-draft", ["draft": [
                "from": "you@example.com", "to": ["sam@example.com", "lee@example.com"], "subject": "Re: Friday review",
                "body": "Hi Sam,\n\nFriday at 14:00 works for me. I will bring the new figures.\n\nBest regards",
            ]]),
        ]),
        sample("Pixel · Design", shape: "cloud", color: .magenta, minutesAgo: 40, preview: "Three icon options are in the shared folder.", unread: 2, chat: [
            me("Can you try a rounder icon?"),
            bot("text", ["content": "Yes. I will keep the colours and change only the shape."]),
            bot("text", ["content": "Three icon options are in the shared folder."]),
        ]),
        sample("Scout · Research", shape: "hex", color: .orange, minutesAgo: 12, preview: "Which flight should I book?", unread: 1, isWaiting: true, chat: [
            me("Find me a flight to Lisbon next week."),
            bot("text", ["content": "I found three direct flights. Prices include one bag."]),
            bot("widget", ["widget": [
                "prompt": "Which flight should I book?",
                "options": [["label": "Thu 07:10 · €142"], ["label": "Thu 12:45 · €189"], ["label": "Fri 06:30 · €98"]],
            ]]),
        ]),
        sample("Ledger · Finance", shape: "squircle", color: .violet, minutesAgo: 1, preview: "On it. I will match the invoices first.", isRunning: true, chat: [
            me("Close the books for October."),
            bot("text", ["content": "On it. I will match the invoices first."]),
        ]),
        sample("Forge · Code", shape: "wedge", color: .red, minutesAgo: 4, preview: "Merge the token refresh fix", unread: 1, isWaiting: true, chat: [
            bot("text", ["content": "The login test failed on main. It is a race in the token refresh."]),
            me("Fix it."),
            bot("text", ["content": "Done. CI is green on the fix."]),
            bot("auto-review-approval", ["approval": [
                "requestId": "demo-approval", "summary": "Merge the token refresh fix", "command": "gh pr merge 412", "status": "pending",
            ]]),
        ]),
        sample("Echo · Notes", shape: "teardrop", color: .cyan, minutesAgo: 26 * 60, preview: "Saved your voice note from the walk.", chat: [
            bot("text", ["content": "Saved your voice note from the walk."]),
        ]),
    ]

    private static func sample(
        _ name: String, shape: String, color: BotColor, minutesAgo: Double, preview: String,
        unread: UInt32 = 0, isRunning: Bool = false, isWaiting: Bool = false, chat: [Row]
    ) -> Sample {
        let id = "demo-" + (name.components(separatedBy: " ").first ?? name).lowercased()
        let lastActivityMs = Int64((Date.now.timeIntervalSince1970 - minutesAgo * 60) * 1000)

        var bot = Bot()
        bot.agentID = id
        bot.name = name
        bot.avatarShape = shape
        bot.avatarColor = color.rawValue
        bot.updatedAtMs = lastActivityMs

        var status = Aiserver_V1_GrokBotAgentStatus()
        status.agentID = id
        status.isRunning = isRunning
        status.client.unreadCount = unread
        status.client.lastActivityAtMs = lastActivityMs
        status.client.notificationsEnabled = true
        status.client.lastEntryPreview.preview = .text(.with { $0.text = preview })
        if isWaiting { status.live.awaiting.sinceMs = lastActivityMs }

        let entries = chat.enumerated().map { index, row in
            var entry = TranscriptEntry()
            entry.seq = UInt64(index + 1)
            entry.updatedSeq = entry.seq
            entry.entryID = "\(id)-\(entry.seq)"
            entry.entryKind = row.kind
            // One minute between entries; the last one is the Bot's last activity.
            let sentAtMs = lastActivityMs - Int64(chat.count - 1 - index) * 60_000
            entry.body = (try? JSONSerialization.data(withJSONObject: row.body.merging(["timestampMs": sentAtMs]) { $1 })) ?? Data()
            return entry
        }
        return Sample(bot: bot, status: status, entries: entries)
    }
}
#endif
