import Foundation

typealias Bot = Aiserver_V1_GrokBotAgent
typealias TranscriptEntry = Aiserver_V1_GrokBotTranscriptEntry
typealias WatchFrame = Aiserver_V1_GrokBotTranscriptWatchFrame

/// The RPCs the watch uses. `agentID` is the Bot's UUID (`GrokBotAgent.agent_id`).
/// Your own Bots have an empty `viewer_session_id`, which the server accepts as the session.
struct GrokBotAPI: Sendable {
    let connect: ConnectClient

    private static let grokBot = "aiserver.v1.GrokBotService/"
    private static let ai = "aiserver.v1.AiService/"

    func bots() async throws -> [Bot] {
        let response: Aiserver_V1_ListGrokBotAgentsResponse =
            try await connect.unary(Self.grokBot + "ListGrokBotAgents", Aiserver_V1_ListGrokBotAgentsRequest())
        return response.agents
    }

    /// Per-Bot client state (hidden, unread, last activity) and running state, keyed by `agentID`.
    func statuses(of bots: [Bot]) async throws -> [String: Aiserver_V1_GrokBotAgentStatus] {
        var request = Aiserver_V1_ListGrokBotAgentStatusesRequest()
        request.agentIds = bots.map(\.agentID)
        let response: Aiserver_V1_ListGrokBotAgentStatusesResponse =
            try await connect.unary(Self.grokBot + "ListGrokBotAgentStatuses", request)
        return Dictionary(response.statuses.map { ($0.agentID, $0) }) { first, _ in first }
    }

    /// Account-synced sidebar settings: pinned Bots and custom sections.
    func runtimeSettings() async throws -> Aiserver_V1_GrokBotUserRuntimeSettings {
        let response: Aiserver_V1_GetGrokBotUserRuntimeSettingsResponse = try await connect.unary(
            Self.grokBot + "GetGrokBotUserRuntimeSettings", Aiserver_V1_GetGrokBotUserRuntimeSettingsRequest()
        )
        return response.settings
    }

    /// The newest `limit` entries, or the ones before `beforeSeq` when paging back.
    func transcript(of bot: Bot, limit: UInt32, before beforeSeq: UInt64? = nil) async throws -> Aiserver_V1_ListGrokBotTranscriptEntriesResponse {
        var request = Aiserver_V1_ListGrokBotTranscriptEntriesRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.limit = limit
        if let beforeSeq { request.beforeSeq = beforeSeq }
        return try await connect.unary(Self.grokBot + "ListGrokBotTranscriptEntries", request)
    }

    /// `messageID` doubles as the user entry's `clientNonce`, which lets the UI match its optimistic bubble.
    func send(_ text: String, to bot: Bot, messageID: String) async throws -> Aiserver_V1_SendGrokBotUserMessageResponse {
        var request = Aiserver_V1_SendGrokBotUserMessageRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.messageID = messageID
        request.text = text
        request.sentAtMs = Int64(Date.now.timeIntervalSince1970 * 1000)
        request.source = .mobile
        request.initiator = .user
        request.sendSource = .chat
        return try await connect.unary(Self.grokBot + "SendGrokBotUserMessage", request)
    }

    /// Live transcript rows and Bot state after `updatedSeq`.
    func watch(_ bot: Bot, generation: UInt32, after updatedSeq: UInt64) -> AsyncThrowingStream<WatchFrame, Error> {
        var cursor = Aiserver_V1_GrokBotTranscriptCursor()
        cursor.agentID = bot.agentID
        cursor.sessionID = bot.viewerSessionID
        cursor.generation = generation
        cursor.afterUpdatedSeq = updatedSeq
        var request = Aiserver_V1_WatchGrokBotTranscriptsRequest()
        request.cursors = [cursor]
        request.inlineBodyMaxBytes = 64 * 1024
        return connect.serverStream(Self.grokBot + "WatchGrokBotTranscripts", request)
    }

    /// Speech in the Bot's own voice (MP3).
    func speech(for text: String, voiceOf bot: Bot) async throws -> Data {
        var request = Aiserver_V1_TextToSpeechRequest()
        request.text = text
        if !bot.voiceID.isEmpty { request.voiceID = bot.voiceID }
        if bot.hasVoiceSpeed { request.speed = bot.voiceSpeed }
        let response: Aiserver_V1_TextToSpeechResponse = try await connect.unary(Self.ai + "TextToSpeech", request)
        return response.audio
    }
}
