import AVFoundation
import Observation

/// Plays Bot replies in the Bot's own voice, one at a time.
@MainActor @Observable
final class Speaker {
    private(set) var speakingID: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    /// `id` names what is playing (a message id), so the UI can show it and stop it.
    func speak(_ text: String, id: String, as bot: Bot, using api: GrokBotAPI) async throws {
        stop()
        speakingID = id
        do {
            let audio = try await api.speech(for: Self.plainText(text), voiceOf: bot)
            guard speakingID == id else { return } // another message took over while loading
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: audio)
            self.player = player
            player.play()
            try await Task.sleep(for: .seconds(player.duration))
        } catch {
            if speakingID == id { speakingID = nil }
            throw error
        }
        if speakingID == id { stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        speakingID = nil
    }

    /// Markdown symbols read badly aloud; speak the rendered text.
    private static func plainText(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
    }
}
