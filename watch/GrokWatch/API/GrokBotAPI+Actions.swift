import Foundation
import SwiftProtobuf

/// The server refused an action (stale card, already answered, and so on).
struct Refusal: LocalizedError {
    let message: String
    var errorDescription: String? { message.isEmpty ? "Grok Bot refused this action." : message }
}

/// Card RPCs answer with `accepted` and an optional refusal.
protocol AcceptingResponse: Message {
    var accepted: Bool { get }
    var hasRefusal: Bool { get }
    var refusal: Aiserver_V1_GrokBotHarnessRefusal { get }
}

extension Aiserver_V1_RespondGrokBotWidgetResponse: AcceptingResponse {}
extension Aiserver_V1_DismissGrokBotWidgetResponse: AcceptingResponse {}
extension Aiserver_V1_SendGrokBotDraftResponse: AcceptingResponse {}
extension Aiserver_V1_DiscardGrokBotDraftResponse: AcceptingResponse {}
extension Aiserver_V1_SubmitGrokBotUserFormResponse: AcceptingResponse {}
extension Aiserver_V1_DismissGrokBotUserFormResponse: AcceptingResponse {}

/// Actions on chat cards and on the Bot list. Request shapes follow the desktop app.
/// `entry_id` is the transcript entry id, which is also the `id` in the entry's JSON body.
extension GrokBotAPI {
    private static let service = "aiserver.v1.GrokBotService/"

    private func accept<Response: AcceptingResponse>(_ method: String, _ request: some Message, as _: Response.Type) async throws {
        let response: Response = try await connect.unary(Self.service + method, request)
        if response.hasRefusal { throw Refusal(message: response.refusal.message) }
        if !response.accepted { throw Refusal(message: "") }
    }

    /// Stops the Bot's current run. Returns false when nothing was running.
    @discardableResult
    func interrupt(_ bot: Bot) async throws -> Bool {
        var request = Aiserver_V1_InterruptGrokBotAgentRunRequest()
        request.agentID = bot.agentID
        request.reason = "user_interrupt"
        if !bot.viewerSessionID.isEmpty { request.sessionID = bot.viewerSessionID }
        let response: Aiserver_V1_InterruptGrokBotAgentRunResponse =
            try await connect.unary(Self.service + "InterruptGrokBotAgentRun", request)
        return response.hadActiveRun
    }

    /// Answers a question card with one option's `value`.
    func answer(_ entryID: String, of bot: Bot, with value: String) async throws {
        var request = Aiserver_V1_RespondGrokBotWidgetRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.entryID = entryID
        request.value = value
        try await accept("RespondGrokBotWidget", request, as: Aiserver_V1_RespondGrokBotWidgetResponse.self)
    }

    func skipQuestion(_ entryID: String, of bot: Bot) async throws {
        var request = Aiserver_V1_DismissGrokBotWidgetRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.entryID = entryID
        try await accept("DismissGrokBotWidget", request, as: Aiserver_V1_DismissGrokBotWidgetResponse.self)
    }

    func resolveApproval(_ requestID: String, of bot: Bot, approve: Bool) async throws {
        var request = Aiserver_V1_ResolveGrokBotAutoReviewApprovalRequest()
        request.agentID = bot.agentID
        request.requestID = requestID
        request.resolution = approve ? .approved : .denied
        request.approvalPlatform = "ios" // the desktop sends "desktop"; the mobile apps send their platform
        if !bot.viewerSessionID.isEmpty { request.sessionID = bot.viewerSessionID }
        let response: Aiserver_V1_ResolveGrokBotAutoReviewApprovalResponse =
            try await connect.unary(Self.service + "ResolveGrokBotAutoReviewApproval", request)
        if !response.dispatched { throw Refusal(message: "") }
    }

    func sendDraft(_ entryID: String, of bot: Bot, draft: Aiserver_V1_SendGrokBotDraftRequest.OneOf_Draft) async throws {
        var request = Aiserver_V1_SendGrokBotDraftRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.entryID = entryID
        request.draft = draft
        try await accept("SendGrokBotDraft", request, as: Aiserver_V1_SendGrokBotDraftResponse.self)
    }

    func discardDraft(_ entryID: String, of bot: Bot) async throws {
        var request = Aiserver_V1_DiscardGrokBotDraftRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.entryID = entryID
        try await accept("DiscardGrokBotDraft", request, as: Aiserver_V1_DiscardGrokBotDraftResponse.self)
    }

    /// `values` maps form field ids to text.
    func submitForm(_ entryID: String, of bot: Bot, values: [String: String]) async throws {
        var request = Aiserver_V1_SubmitGrokBotUserFormRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.entryID = entryID
        request.values = values
        request.platform = .ios
        try await accept("SubmitGrokBotUserForm", request, as: Aiserver_V1_SubmitGrokBotUserFormResponse.self)
    }

    func dismissForm(_ entryID: String, of bot: Bot) async throws {
        var request = Aiserver_V1_DismissGrokBotUserFormRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.entryID = entryID
        request.mode = .dismissed
        request.platform = .ios
        try await accept("DismissGrokBotUserForm", request, as: Aiserver_V1_DismissGrokBotUserFormResponse.self)
    }

    func react(to entryID: String, of bot: Bot, with emoji: String) async throws {
        var request = Aiserver_V1_ReactToGrokBotMessageRequest()
        request.agentID = bot.agentID
        request.sessionID = bot.viewerSessionID
        request.entryID = entryID
        request.emoji = emoji
        let response: Aiserver_V1_ReactToGrokBotMessageResponse =
            try await connect.unary(Self.service + "ReactToGrokBotMessage", request)
        if response.hasRefusal { throw Refusal(message: response.refusal.message) }
    }

    /// Signed download URLs for attachment paths (`file://…` URLs or box paths). Missing files are left out.
    func attachmentURLs(_ paths: [String], of bot: Bot) async throws -> [String: Aiserver_V1_GrokBotAttachmentRead] {
        var request = Aiserver_V1_ResolveGrokBotAttachmentReadsRequest()
        request.agentID = bot.agentID
        if !bot.viewerSessionID.isEmpty { request.sessionID = bot.viewerSessionID }
        request.paths = paths
        let response: Aiserver_V1_ResolveGrokBotAttachmentReadsResponse =
            try await connect.unary(Self.service + "ResolveGrokBotAttachmentReads", request)
        let found = response.reads.filter { $0.outcome == .store && !$0.url.isEmpty }
        return Dictionary(found.map { ($0.path, $0) }) { first, _ in first }
    }

    // MARK: Bot list

    /// Replaces the account's pinned Bots (synced to every device).
    func setPinned(_ agentIDs: [String]) async throws {
        var request = Aiserver_V1_UpdateGrokBotUserRuntimeSettingsRequest()
        request.pinnedAgents.agentIds = agentIDs
        let _: Aiserver_V1_UpdateGrokBotUserRuntimeSettingsResponse =
            try await connect.unary(Self.service + "UpdateGrokBotUserRuntimeSettings", request)
    }

    /// Changes one piece of a Bot's per-account client state, e.g. `\.hiddenFromSidebar` or `\.markUnread`.
    func setClientState(
        of bot: Bot, _ field: WritableKeyPath<Aiserver_V1_SetGrokBotAgentClientStateRequest, Bool>, to value: Bool
    ) async throws {
        var request = Aiserver_V1_SetGrokBotAgentClientStateRequest()
        request.agentID = bot.agentID
        request[keyPath: field] = value
        let _: Aiserver_V1_SetGrokBotAgentClientStateResponse =
            try await connect.unary(Self.service + "SetGrokBotAgentClientState", request)
    }
}
