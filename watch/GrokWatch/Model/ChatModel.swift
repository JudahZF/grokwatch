import Foundation
import Observation

/// One Bot's chat: recent history, then the live transcript stream.
@MainActor @Observable
final class ChatModel {
    let bot: Bot
    private(set) var messages: [ChatMessage] = []
    private(set) var isWorking = false
    /// What the Bot is doing right now ("Thinking…", a tool, "Writing…"). Nil when idle.
    private(set) var activity: String?
    private(set) var status: String?
    private(set) var hasEarlier = false
    /// Messages with an action in flight. Their cards show a spinner instead of buttons.
    private(set) var busyIDs: Set<String> = []

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var generation: UInt32 = 0
    @ObservationIgnored private var cursor: UInt64 = 0
    @ObservationIgnored private var oldestSeq: UInt64?
    @ObservationIgnored private var needsReload = true
    /// Counts live-state frames, so `send` does not overwrite newer state with "Thinking…".
    @ObservationIgnored private var stateUpdates = 0
    @ObservationIgnored private var imageReads: [String: Aiserver_V1_GrokBotAttachmentRead] = [:]
    private static let pageSize: UInt32 = 30

    init(bot: Bot, session: AppSession) {
        self.bot = bot
        self.session = session
    }

    /// Follows the Bot until the view goes away. Reconnects after drops; reloads history when the server says so.
    func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                if needsReload { try await reload() }
                status = nil
                var isFirstFrame = true
                for try await frame in session.api.watch(bot, generation: generation, after: cursor) {
                    if isFirstFrame {
                        isFirstFrame = false
                        failures = 0
                        markRead()
                    }
                    guard apply(frame) else { break }
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .timedOut {
                // The stream went idle (no heartbeat): reconnect quietly.
            } catch {
                if Task.isCancelled { return }
                status = session.describe(error)
                failures += 1
            }
            try? await Task.sleep(for: ConnectClient.reconnectDelay(afterFailures: failures))
        }
    }

    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        messages.append(ChatMessage(id: id, entryID: id, seq: .max, author: .me, content: .text(text), sentAt: .now, isPending: true))
        await deliver(text, id: id)
    }

    /// Sends a failed message again. The id is the same, and the server drops a duplicate, so this cannot send twice.
    func retry(_ message: ChatMessage) async {
        guard message.isFailed, case .text(let text) = message.content,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isFailed = false
        status = nil
        await deliver(text, id: message.id)
    }

    private func deliver(_ text: String, id: String) async {
        let updatesBeforeSend = stateUpdates
        do {
            let response = try await session.api.send(text, to: bot, messageID: id)
            if response.hasRefusal {
                messages.removeAll { $0.id == id && $0.isPending }
                status = response.refusal.message
            } else if stateUpdates == updatesBeforeSend {
                // Only if no live state arrived meanwhile (the turn may already be over).
                isWorking = true
                activity = "Thinking…"
            }
        } catch {
            // Keep the text: dictation on a watch is slow to repeat. A bubble the stream already confirmed is not pending.
            if let index = messages.firstIndex(where: { $0.id == id && $0.isPending }) { messages[index].isFailed = true }
            status = session.describe(error)
        }
    }

    func stop() async {
        do {
            try await session.api.interrupt(bot)
            isWorking = false
            activity = nil
        } catch {
            status = session.describe(error)
        }
    }

    func speak(_ message: ChatMessage) async {
        guard let text = message.spokenText else { return }
        do {
            try await session.speaker.speak(text, id: message.id, as: bot, using: session.api)
        } catch {
            status = session.describe(error)
        }
    }

    // MARK: Cards

    func answer(_ message: ChatMessage, with option: Question.Option) async {
        await act(on: message) { api, bot in try await api.answer(message.entryID, of: bot, with: option.value) } then: {
            if case .question(var question) = $0 { question.state = .answered(option.value); $0 = .question(question) }
        }
    }

    func skip(_ message: ChatMessage) async {
        await act(on: message) { api, bot in try await api.skipQuestion(message.entryID, of: bot) } then: {
            if case .question(var question) = $0 { question.state = .skipped; $0 = .question(question) }
        }
    }

    func resolve(_ message: ChatMessage, as resolution: Aiserver_V1_GrokBotAutoReviewApprovalResolution) async {
        guard case .approval(let approval) = message.content else { return }
        await act(on: message) { api, bot in try await api.resolveApproval(approval.requestID, of: bot, as: resolution) } then: {
            if case .approval(var approval) = $0 { approval.status = resolution.status; $0 = .approval(approval) }
        }
    }

    func sendDraft(_ message: ChatMessage) async {
        guard case .draft(let draft) = message.content else { return }
        await act(on: message) { api, bot in try await api.sendDraft(message.entryID, of: bot, draft: draft.payload) } then: {
            if case .draft(var draft) = $0 { draft.state = "sending"; $0 = .draft(draft) }
        }
    }

    func discardDraft(_ message: ChatMessage) async {
        await act(on: message) { api, bot in try await api.discardDraft(message.entryID, of: bot) } then: {
            if case .draft(var draft) = $0 { draft.state = "discarded"; $0 = .draft(draft) }
        }
    }

    func submit(_ message: ChatMessage, values: [String: String]) async {
        await act(on: message) { api, bot in try await api.submitForm(message.entryID, of: bot, values: values) } then: {
            if case .form(var form) = $0 { form.isOpen = false; $0 = .form(form) }
        }
    }

    func dismissForm(_ message: ChatMessage) async {
        await act(on: message) { api, bot in try await api.dismissForm(message.entryID, of: bot) } then: {
            if case .form(var form) = $0 { form.isOpen = false; $0 = .form(form) }
        }
    }

    func react(to message: ChatMessage, with emoji: String) async {
        await act(on: message) { api, bot in try await api.react(to: message.entryID, of: bot, with: emoji) } then: { _ in }
    }

    /// Runs a card action, then applies the local result until the server's updated row arrives.
    private func act(
        on message: ChatMessage,
        _ action: @Sendable (GrokBotAPI, Bot) async throws -> Void,
        then update: (inout ChatMessage.Content) -> Void
    ) async {
        busyIDs.insert(message.id)
        defer { busyIDs.remove(message.id) }
        do {
            try await action(session.api, bot)
            status = nil
            if let index = messages.firstIndex(where: { $0.id == message.id }) { update(&messages[index].content) }
        } catch {
            status = session.describe(error)
        }
    }

    // MARK: Attachments

    /// A signed download URL for an attachment, or nil when it is missing or too large for the watch.
    /// Signed URLs expire, so a cached one is reused only while it has more than a minute left (0: no expiry set).
    func imageURL(for path: String) async -> URL? {
        let freshUntilMs = Int64(Date.now.addingTimeInterval(60).timeIntervalSince1970 * 1000)
        let isFresh = imageReads[path].map { $0.expiresAtMs == 0 || $0.expiresAtMs > freshUntilMs } ?? false
        if !isFresh, let reads = try? await session.api.attachmentURLs([path], of: bot) {
            imageReads.merge(reads) { _, new in new }
        }
        guard let read = imageReads[path], read.sizeBytes <= 4_000_000 else { return nil }
        return URL(string: read.url)
    }

    // MARK: History

    func loadEarlier() async {
        guard let oldestSeq else { return }
        let generation = generation
        do {
            let page = try await session.api.transcript(of: bot, limit: Self.pageSize, before: oldestSeq)
            guard generation == self.generation else { return } // history was reset meanwhile
            self.oldestSeq = page.entries.map(\.seq).min() ?? oldestSeq
            hasEarlier = page.entries.count >= Self.pageSize
            let known = Set(messages.map(\.id))
            let earlier = page.entries.compactMap { ChatMessage(entry: $0, viewer: bot.viewerName) }.filter { !known.contains($0.id) }
            messages = earlier.sorted { $0.seq < $1.seq } + messages
            messages.settleQuestions()
        } catch {
            status = session.describe(error)
        }
    }

    /// Clears the Bot's unread count for this account (all devices). Best effort.
    private func markRead() {
        Task { [api = session.api, bot] in try? await api.setClientState(of: bot, \.markRead, to: true) }
    }

    private func reload() async throws {
        let page = try await session.api.transcript(of: bot, limit: Self.pageSize)
        generation = page.generation
        cursor = page.entries.map(\.updatedSeq).max() ?? 0
        oldestSeq = page.entries.map(\.seq).min()
        hasEarlier = page.entries.count >= Self.pageSize
        let loaded = page.entries.compactMap { ChatMessage(entry: $0, viewer: bot.viewerName) }.sorted { $0.seq < $1.seq }
        let loadedIDs = Set(loaded.map(\.id))
        messages = loaded + messages.filter { $0.isPending && !loadedIDs.contains($0.id) }
        messages.settleQuestions()
        needsReload = false
    }

    /// Returns false when the stream must restart (history reset on the server).
    private func apply(_ frame: WatchFrame) -> Bool {
        switch frame.frame {
        case .rows(let rows):
            for entry in rows.entries {
                cursor = max(cursor, entry.updatedSeq)
                if let message = ChatMessage(entry: entry, viewer: bot.viewerName) { upsert(message, live: !rows.replay) }
            }
            for deletion in rows.deletes {
                cursor = max(cursor, deletion.updatedSeq)
                messages.removeAll { $0.seq == deletion.seq }
            }
        case .agentState(let state):
            if let live = state.live.first(where: { $0.agentID == bot.agentID }) {
                show(live)
            } else if state.snapshot {
                stateUpdates += 1
                isWorking = false
                activity = nil
            }
        case .turnFailed(let failure):
            isWorking = false
            activity = nil
            status = failure.summary.isEmpty ? "The Bot's turn failed." : failure.summary
        case .cleared, .cursorTooOld:
            needsReload = true
            return false
        default:
            break
        }
        return true
    }

    private func show(_ live: Aiserver_V1_GrokBotAgentLiveState) {
        stateUpdates += 1
        isWorking = live.isRunning
        guard live.isRunning else { activity = nil; return }
        activity = if live.isComposingMessage {
            "Writing…"
        } else if live.isRetrying {
            "Retrying…"
        } else if live.hasActivity, !live.activity.detail.isEmpty {
            live.activity.detail
        } else if live.hasActivity, !live.activity.tool.isEmpty {
            "Using \(live.activity.tool)…"
        } else {
            "Thinking…"
        }
    }

    private func upsert(_ message: ChatMessage, live: Bool) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            let index = messages.firstIndex { $0.seq > message.seq } ?? messages.endIndex
            messages.insert(message, at: index)
            if live, message.author == .bot {
                markRead() // you are looking at it, as on the phone
                if session.autoSpeak, !session.isInCall, case .text = message.content { Task { await speak(message) } }
            }
        }
        messages.settleQuestions()
    }
}

extension Bot {
    /// Your display name in a group or shared chat. Nil in a chat with only you and the Bot.
    var viewerName: String? { people.first(where: \.isViewer)?.displayName }
}

extension Aiserver_V1_GrokBotAutoReviewApprovalResolution {
    /// The approval `status` the server writes for this answer.
    var status: String {
        switch self {
        case .approved: "approved"
        case .always: "always"
        default: "denied"
        }
    }
}
