import Foundation
import SwiftProtobuf

/// Live voice calls. The realtime model (xAI) is a front end; the harness RPCs give it the Bot's persona and tools.
/// See "Voice" in docs/grok-bot-protocol.md.
extension GrokBotAPI {
    private static let voiceService = "aiserver.v1.GrokBotService/"

    /// A short-lived secret for the realtime WebSocket. The desktop sends an empty request.
    func mintVoiceSecret() async throws -> Aiserver_V1_MintSandVoiceCallSecretResponse {
        try await connect.unary(Self.voiceService + "MintSandVoiceCallSecret", Aiserver_V1_MintSandVoiceCallSecretRequest())
    }

    /// Instructions, tools, greeting, and the task receipt for one call.
    func voicePlan(for bot: Bot) async throws -> Aiserver_V1_VoiceCallHarnessSessionResponse {
        var request = Aiserver_V1_VoiceCallHarnessSessionRequest()
        request.agentID = bot.agentID
        request.agentName = bot.name
        request.hasSpeedSetting_p = true
        return try await connect.unary(Self.voiceService + "VoiceCallHarnessSession", request)
    }

    /// Serves one tool call from the realtime model. `input` and the result are JSON.
    func voiceTool(_ name: String, input: String, bot: Bot, callID: String) async throws -> Aiserver_V1_VoiceCallHarnessToolResponse {
        var request = Aiserver_V1_VoiceCallHarnessToolRequest()
        request.agentID = bot.agentID
        request.callID = callID
        request.name = name
        request.input = (try? Google_Protobuf_Value(jsonString: input)) ?? Google_Protobuf_Value(structValue: Google_Protobuf_Struct())
        request.line = Aiserver_V1_VoiceCallLineState()
        return try await connect.unary(Self.voiceService + "VoiceCallHarnessTool", request)
    }

    /// Saves the finished call, so it shows in the Bot's chat. `record` is the desktop's call record JSON.
    func recordVoiceCall(_ record: String, bot: Bot) async throws {
        var request = Aiserver_V1_RecordGrokBotVoiceCallRequest()
        request.agentID = bot.agentID
        request.record = try Google_Protobuf_Struct(jsonString: record)
        let _: Aiserver_V1_RecordGrokBotVoiceCallResponse =
            try await connect.unary(Self.voiceService + "RecordGrokBotVoiceCall", request)
    }
}
