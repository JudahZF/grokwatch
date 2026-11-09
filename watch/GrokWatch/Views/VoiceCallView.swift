import SwiftUI

struct VoiceCallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var call: VoiceCall

    init(bot: Bot, session: AppSession) {
        _call = State(initialValue: VoiceCall(bot: bot, session: session))
    }

    var body: some View {
        VStack(spacing: 6) {
            avatar
                .onTapGesture { if call.isBotSpeaking { call.interrupt() } }
            Text(status).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
            if let line = call.lines.last {
                Text(line.spoken)
                    .font(.caption2)
                    .foregroundStyle(line.isBot ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .id(line.id)
            }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                Button {
                    call.isMuted.toggle()
                } label: {
                    Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                }
                .tint(call.isMuted ? .orange : .gray)
                .accessibilityLabel(call.isMuted ? "Unmute" : "Mute")
                Button {
                    call.hangUp()
                } label: {
                    Image(systemName: "phone.down.fill")
                }
                .tint(.red)
                .accessibilityLabel("End call")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isEnded)
        }
        .animation(.snappy, value: call.lines.last)
        .animation(.snappy, value: status)
        .toolbar(.hidden, for: .navigationBar)
        .task { await call.start() }
        .onDisappear { call.hangUp() }
        .onChange(of: isEnded) {
            Task {
                try? await Task.sleep(for: .seconds(call.phase == .ended(nil) ? 0.8 : 3))
                dismiss()
            }
        }
    }

    private var isEnded: Bool {
        if case .ended = call.phase { true } else { false }
    }

    private var status: String {
        switch call.phase {
        case .connecting: "Calling…"
        case .live: call.isBotSpeaking ? "Speaking · tap to cut in" : call.isMuted ? "Muted" : "Listening"
        case .ended(let reason): reason ?? "Call ended"
        }
    }

    private var avatar: some View {
        AsyncImage(url: URL(string: call.bot.avatarURL)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(call.bot.displayParts.name.prefix(1)).font(.title2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.tint.opacity(0.4))
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
        .padding(5)
        .overlay {
            // The ring only moves while the Bot speaks.
            Circle().strokeBorder(.tint, lineWidth: 2)
                .phaseAnimator([false, true], trigger: call.isBotSpeaking) { ring, grown in
                    ring.scaleEffect(call.isBotSpeaking && grown ? 1.12 : 1)
                        .opacity(call.phase == .live ? 1 : 0.3)
                }
        }
    }
}
