import AVFoundation
import Foundation
import Observation

/// A live voice call with a Bot, following the desktop's call flow:
/// mint a secret, get the call plan, open the xAI realtime socket, greet, then serve the plan's tools.
/// Work goes to the real Bot through `send_task`; the Bot's replies come back into the call as `work_landed` notes.
@MainActor @Observable
final class VoiceCall {
    enum Phase: Equatable {
        case connecting
        case live
        case ended(String?)
    }

    struct Line: Identifiable, Equatable {
        let id: String
        let isBot: Bool
        /// Raw transcript. The model sometimes repeats itself inside `<response_segment_N_already_spoken>` tags.
        var text: String
        let atMs: Int64

        var spoken: String {
            text.replacing(/<response_segment_\d+_already_spoken>[\s\S]*?(<\/response_segment_\d+_already_spoken>|$)/, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    let bot: Bot
    private(set) var phase: Phase = .connecting
    private(set) var lines: [Line] = []
    private(set) var isBotSpeaking = false
    var isMuted = false { didSet { audio.isMuted = isMuted } }

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let callID = UUID().uuidString.lowercased()
    @ObservationIgnored private let audio = CallAudio()
    @ObservationIgnored private let line = CallLine()
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var plan = Aiserver_V1_VoiceCallHarnessSessionResponse()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var hasGreeted = false
    @ObservationIgnored private var conversationID: String?
    @ObservationIgnored private let startedAt = Date.now
    @ObservationIgnored private var record = CallRecord()

    init(bot: Bot, session: AppSession) {
        self.bot = bot
        self.session = session
        #if DEBUG
        // Simulator testing: SIMCTL_CHILD_GROKWATCH_SILENT_CALL=1 mutes the mic and the speaker.
        if ProcessInfo.processInfo.environment["GROKWATCH_SILENT_CALL"] != nil {
            isMuted = true
            audio.isMuted = true
            audio.isSilent = true
        }
        #endif
    }

    func start() async {
        session.isInCall = true
        session.speaker.stop()
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                return end(because: "Turn on microphone access for Grokwatch in Settings.")
            }
            async let secret = session.api.mintVoiceSecret()
            async let plan = session.api.voicePlan(for: bot)
            let (credential, callPlan) = try await (secret, plan)
            self.plan = callPlan
            line.onEnded = { [weak self] in self?.hangUp() }
            if (try? await line.start(calling: bot.displayParts.name)) != true {
                // CallKit did not start or activate audio (e.g. the simulator): run the audio session ourselves.
                try AVAudioSession.sharedInstance().setCategory(audio.isSilent ? .playback : .playAndRecord, mode: callAudioMode)
                try AVAudioSession.sharedInstance().setActive(true)
            }
            guard phase == .connecting else { return }
            try open(credential)
            startFollowingTheBot()
            watchAudioInterruptions()
            tasks.append(Task {
                try? await Task.sleep(for: .seconds(15))
                if phase == .connecting { end(because: "The call could not connect.") }
            })
        } catch {
            end(because: session.describe(error))
        }
    }

    /// Ends the call from the watch. Safe to call more than once.
    func hangUp() { end(because: nil) }

    /// Stops the Bot mid-sentence.
    func interrupt() {
        audio.flush()
        isBotSpeaking = false
        send(["type": "response.cancel"])
    }

    // MARK: Socket

    private func open(_ credential: Aiserver_V1_MintSandVoiceCallSecretResponse) throws {
        guard var url = URLComponents(string: credential.websocketURL) else { throw URLError(.badURL) }
        url.queryItems = (url.queryItems ?? []) + [URLQueryItem(name: "model", value: credential.model)]
        guard let socketURL = url.url else { throw URLError(.badURL) }
        let socket = URLSession.shared.webSocketTask(with: socketURL, protocols: ["xai-client-secret.\(credential.clientSecret)"])
        self.socket = socket
        socket.resume()
        send(sessionUpdate())
        tasks.append(Task { await receive(from: socket) })
    }

    private func sessionUpdate() -> [String: Any] {
        let format: [String: Any] = ["type": "audio/pcm", "rate": Int(CallAudio.sampleRate)]
        var config: [String: Any] = [
            "instructions": plan.instructions,
            "resumption": ["enabled": false],
            "turn_detection": ["type": "server_vad"],
            "audio": [
                "input": ["format": format, "transcription": ["model": "grok-transcribe"]],
                "output": ["format": format, "speed": bot.hasVoiceSpeed ? Double(bot.voiceSpeed) : 1.0],
            ],
            "tools": plan.tools.compactMap { tool -> [String: Any]? in
                guard let parameters = try? JSONSerialization.jsonObject(with: tool.parameters.jsonUTF8Data()) else { return nil }
                return ["type": tool.type, "name": tool.name, "description": tool.description_p, "parameters": parameters]
            },
        ]
        if !bot.voiceID.isEmpty { config["voice"] = bot.voiceID }
        return ["type": "session.update", "session": config]
    }

    private func send(_ frame: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func receive(from socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message,
                      let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                handle(event)
            } catch {
                if case .ended = phase { return }
                return end(because: socket.closeCode == .normalClosure ? nil : "The call dropped.")
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "session.updated":
            guard !hasGreeted else { return }
            hasGreeted = true
            Task {
                await startAudio()
                ask(plan.greeting.direction)
            }
        case "conversation.created":
            conversationID = (event["conversation"] as? [String: Any])?["id"] as? String
        case "response.output_audio.delta", "response.audio.delta":
            guard let delta = event["delta"] as? String, let pcm = Data(base64Encoded: delta) else { return }
            audio.play(pcm)
            isBotSpeaking = true
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let delta = event["delta"] as? String else { return }
            append(delta, isBot: true, itemID: event["item_id"] as? String ?? "bot")
        case "conversation.item.input_audio_transcription.completed":
            guard let text = (event["transcript"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return }
            append(text, isBot: false, itemID: event["item_id"] as? String ?? UUID().uuidString)
        case "response.done", "response.cancelled":
            Task { await watchSpeechEnd() }
        case "response.function_call_arguments.done":
            guard let callID = event["call_id"] as? String, let name = event["name"] as? String else { return }
            Task { await serveTool(name, arguments: event["arguments"] as? String ?? "{}", toolCallID: callID) }
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
            record.events.append(["kind": "protocol-error", "atMs": nowMs])
            if phase == .connecting { end(because: message ?? "The call could not start.") }
        default:
            break
        }
    }

    private func startAudio() async {
        guard let socket, phase == .connecting else { return }
        do {
            try await Task.detached { [audio] in
                try audio.start { pcm in
                    let frame = #"{"type":"input_audio_buffer.append","audio":"\#(pcm.base64EncodedString())"}"#
                    socket.send(.string(frame)) { _ in }
                }
            }.value
            guard phase == .connecting else { return }
            phase = .live
            line.connected()
        } catch {
            end(because: error.localizedDescription)
        }
    }

    /// Asks the model to speak now, optionally with extra instructions.
    private func ask(_ instructions: String?) {
        if let instructions, !instructions.isEmpty {
            send(["type": "response.create", "response": ["instructions": instructions]])
        } else {
            send(["type": "response.create"])
        }
    }

    private func watchSpeechEnd() async {
        while audio.isPlaying { try? await Task.sleep(for: .milliseconds(150)) }
        isBotSpeaking = false
    }

    private func append(_ text: String, isBot: Bool, itemID: String) {
        if let index = lines.firstIndex(where: { $0.id == itemID }) {
            lines[index].text += text
        } else {
            lines.append(Line(id: itemID, isBot: isBot, text: text, atMs: nowMs))
        }
    }

    // MARK: Tools

    private func serveTool(_ name: String, arguments: String, toolCallID: String) async {
        record.toolCalls.append(["name": name, "atMs": nowMs])
        switch name {
        case "send_task":
            // Speak the receipt now; the Bot's answer arrives later in its transcript.
            let request = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])?["request"] as? String ?? arguments
            record.nudges.append(["id": "nudge-\(UUID().uuidString.lowercased())", "request": request, "atMs": nowMs,
                                  "direction": "to-main", "answer": NSNull()])
            sendToolOutput(toolCallID, output: (try? plan.receipt.output.jsonString()) ?? #"{"receipt":"under way"}"#)
            ask(plan.receipt.instructions)
            let input = (try? JSONSerialization.data(withJSONObject: ["request": request])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            if let result = try? await session.api.voiceTool(name, input: input, bot: bot, callID: callID),
               let relay = try? JSONSerialization.jsonObject(with: result.output.jsonUTF8Data()) as? [String: Any],
               relay["relay"] as? String != "accepted", let spoken = relay["spoken"] as? String {
                landed(spoken)
            }
        case "end_the_call":
            _ = try? await session.api.voiceTool(name, input: arguments, bot: bot, callID: callID)
            sendToolOutput(toolCallID, output: "{}")
            try? await Task.sleep(for: .seconds(1))
            await watchSpeechEnd()
            hangUp()
        default:
            do {
                let result = try await session.api.voiceTool(name, input: arguments, bot: bot, callID: callID)
                sendToolOutput(toolCallID, output: (try? result.output.jsonString()) ?? "{}")
            } catch {
                sendToolOutput(toolCallID, output: #"{"error":"tool unavailable"}"#)
            }
            ask(nil)
        }
    }

    private func sendToolOutput(_ toolCallID: String, output: String) {
        send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": toolCallID, "output": output]])
    }

    /// Hands news from the Bot to the voice model and has it speak (desktop: "asked" nudge delivery).
    private func landed(_ text: String) {
        guard phase == .live else { return }
        let noteID = "nudge-\(UUID().uuidString.lowercased())"
        let note: [String: Any] = ["status": "landed", "updates": [text], "at": ISO8601DateFormatter().string(from: .now)]
        let output = (try? JSONSerialization.data(withJSONObject: note)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        send(["type": "conversation.item.create", "item": ["type": "function_call", "name": "work_landed", "call_id": noteID, "arguments": "{}"]])
        send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": noteID, "output": output]])
        ask(nil)
        record.nudges.append(["id": noteID, "request": "news", "atMs": nowMs, "direction": "to-voice", "answer": text, "answeredAtMs": nowMs])
    }

    /// Forwards the Bot's new chat replies (answers to `send_task`) into the call, once each. Reconnects after drops.
    private func startFollowingTheBot() {
        tasks.append(Task { [api = session.api, bot] in
            var seen: Set<String> = []
            var head: Aiserver_V1_ListGrokBotTranscriptEntriesResponse?
            var cursor: UInt64 = 0
            var failures = 0
            while !Task.isCancelled {
                do {
                    if head == nil {
                        let page = try await api.transcript(of: bot, limit: 1)
                        head = page
                        cursor = page.entries.map(\.updatedSeq).max() ?? 0
                    }
                    stream: for try await frame in api.watch(bot, generation: head?.generation ?? 0, after: cursor) {
                        failures = 0
                        switch frame.frame {
                        case .rows(let rows):
                            for entry in rows.entries {
                                cursor = max(cursor, entry.updatedSeq)
                                guard !rows.replay, entry.entryKind == "send-message", seen.insert(entry.entryID).inserted,
                                      let message = ChatMessage(entry: entry), case .text(let text) = message.content else { continue }
                                landed(text)
                            }
                        case .cleared, .cursorTooOld:
                            head = nil
                            break stream
                        default:
                            break
                        }
                    }
                } catch let error as URLError where error.code == .timedOut {
                    // The stream went idle (no heartbeat): a normal reconnect.
                } catch {
                    failures += 1
                }
                try? await Task.sleep(for: ConnectClient.reconnectDelay(afterFailures: failures))
            }
        })
    }

    /// Siri, an alarm, or a route change can stop the engine. Restart it; end the call if that fails.
    private func watchAudioInterruptions() {
        tasks.append(Task { [audio] in
            for await _ in audio.configurationChanges {
                do { try audio.restart() } catch { end(because: "Call audio stopped.") }
            }
        })
        tasks.append(Task { [audio] in
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                if type == .ended {
                    do { try audio.restart() } catch { end(because: "Call audio stopped.") }
                } else {
                    audio.flush()
                }
                isBotSpeaking = false
            }
        })
    }

    // MARK: Ending

    private var nowMs: Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }

    private func end(because reason: String?) {
        if case .ended = phase { return }
        let wasLive = phase == .live
        phase = .ended(reason)
        session.isInCall = false
        isBotSpeaking = false
        tasks.forEach { $0.cancel() }
        audio.stop()
        socket?.cancel(with: .normalClosure, reason: Data("hang_up".utf8))
        Task { [line] in await line.end() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if wasLive { save(ending: reason == nil ? "hung-up" : "disconnected") }
    }

    /// Best effort: the desktop records each call so it shows in the chat.
    private func save(ending: String) {
        let turns = lines.map { ["id": $0.id, "speaker": $0.isBot ? "assistant" : "user", "text": $0.spoken, "atMs": $0.atMs] as [String: Any] }
        let started = Int64(startedAt.timeIntervalSince1970 * 1000)
        var json: [String: Any] = [
            "callId": callID, "agentId": bot.agentID, "startedAtMs": started, "endedAtMs": nowMs,
            "durationMs": nowMs - started, "ending": ending, "turns": turns, "nudges": record.nudges,
            "events": record.events, "toolCalls": record.toolCalls, "overheard": [Any](), "harnessMayCollect": false,
        ]
        if let conversationID { json["realtimeConversationId"] = conversationID }
        guard let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) else { return }
        Task { [api = session.api, bot] in try? await api.recordVoiceCall(text, bot: bot) }
    }
}

/// What the call record collects while the call runs.
private struct CallRecord {
    var nudges: [[String: Any]] = []
    var events: [[String: Any]] = []
    var toolCalls: [[String: Any]] = []
}
