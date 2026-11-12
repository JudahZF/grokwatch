import ImageIO
import SwiftUI
import WatchKit

struct ChatView: View {
    @Environment(AppSession.self) private var session
    @State private var model: ChatModel
    @State private var actionsFor: ChatMessage?
    @State private var isCalling = false

    init(bot: Bot, session: AppSession) {
        _model = State(initialValue: ChatModel(bot: bot, session: session))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a page is 30 messages, and a lazy stack makes the jump to the end miss.
                VStack(spacing: 6) {
                    if model.hasEarlier {
                        Button("Earlier messages") { Task { await model.loadEarlier() } }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        if let time = timeLabel(at: index) {
                            Text(time).font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                        }
                        if let sender = senderLabel(at: index) {
                            Text(sender).font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                        }
                        MessageRow(message: message, model: model, onLongPress: { actionsFor = message })
                            .id(message.id)
                    }
                    if let activity = model.activity {
                        TypingRow(text: activity).transition(.opacity)
                    }
                    if let status = model.status {
                        Text(status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .animation(.snappy, value: model.activity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.last?.id) { previous, _ in
                // An open card shows from its top, so its question is visible; anything else scrolls to the end.
                let scroll = {
                    if let last = model.messages.last, last.needsAnswer {
                        proxy.scrollTo(last.id, anchor: .top)
                    } else {
                        proxy.scrollTo(Self.endID, anchor: .bottom)
                    }
                }
                if previous == nil { scroll() } else { withAnimation(.default, scroll) }
            }
        }
        // Always on screen, as on the phone, so a reply never needs a scroll to the end of the chat.
        .safeAreaInset(edge: .bottom, spacing: 2) {
            Composer(bot: model.bot) { text in Task { await model.send(text) } }
        }
        .navigationTitle {
            Label {
                Text(model.bot.displayParts.name)
            } icon: {
                BotAvatar(bot: model.bot).frame(width: 18, height: 18)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isWorking {
                    Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop")
                } else {
                    Button { isCalling = true } label: { Image(systemName: "phone.fill") }
                        .accessibilityLabel("Call")
                }
            }
        }
        .fullScreenCover(isPresented: $isCalling) {
            VoiceCallView(bot: model.bot, session: session)
        }
        .sheet(item: $actionsFor) { message in
            MessageActions(message: message, model: model)
        }
        .task { await model.run() }
        #if DEBUG
        // Simulator testing: SIMCTL_CHILD_GROKWATCH_CALL=1 (with GROKWATCH_OPEN_BOT) starts a call.
        .onAppear { if ProcessInfo.processInfo.environment["GROKWATCH_CALL"] != nil { isCalling = true } }
        #endif
    }

    private static let endID = "end"

    /// The writer's name, before the first message of each run by a group member or another person.
    private func senderLabel(at index: Int) -> String? {
        guard let sender = model.messages[index].sender else { return nil }
        return index > 0 && model.messages[index - 1].sender == sender ? nil : sender
    }

    /// A time header before the first message and after gaps of 20 minutes or more.
    private func timeLabel(at index: Int) -> String? {
        guard let date = model.messages[index].sentAt else { return nil }
        if index > 0, let previous = model.messages[index - 1].sentAt, date.timeIntervalSince(previous) < 20 * 60 { return nil }
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

private struct MessageRow: View {
    @Environment(AppSession.self) private var session
    let message: ChatMessage
    let model: ChatModel
    let onLongPress: () -> Void

    var body: some View {
        VStack(alignment: message.author == .me ? .trailing : .leading, spacing: 2) {
            content
            if !message.reactions.isEmpty {
                Text(message.reactions.joined(separator: " ")).font(.caption2)
            }
            if message.isFailed {
                Text("Not sent · Tap to retry").font(.caption2).foregroundStyle(Theme.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .animation(.snappy, value: message)
        .onLongPressGesture(perform: onLongPress)
    }

    private var alignment: Alignment {
        switch message.author {
        case .me: .trailing
        case .bot: .leading
        case .system: .center
        }
    }

    @ViewBuilder private var content: some View {
        switch message.content {
        case .text(let text):
            Bubble(fill: myFill, isPending: message.isPending) {
                MarkdownText(text)
                if session.speaker.speakingID == message.id {
                    Image(systemName: "speaker.wave.2.fill").font(.caption2).symbolEffect(.variableColor)
                }
            }
            .onTapGesture {
                if message.isFailed { Task { await model.retry(message) } } else { toggleSpeech() }
            }
        case .image(let path, let caption):
            AttachmentImage(path: path, caption: caption, model: model)
        case .file(let name):
            Bubble(fill: myFill, isPending: false) {
                Label(name, systemImage: "doc").font(.footnote).lineLimit(2)
            }
        case .notice(let text):
            Text(text).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 6)
        case .question(let question):
            QuestionCard(message: message, question: question, model: model)
        case .approval(let approval):
            ApprovalCard(message: message, approval: approval, model: model)
        case .draft(let draft):
            DraftCard(message: message, draft: draft, model: model)
        case .form(let form):
            FormCard(message: message, form: form, model: model)
        case .phoneOnly(let title, let detail, let done):
            PhoneOnlyCard(title: title, detail: detail, done: done)
        }
    }

    /// The fill of your own bubble, or nil for a bubble from the Bot side.
    private var myFill: BubbleFill? {
        guard message.author == .me else { return nil }
        if session.bubbleStyle == .botColor, let color = model.bot.color.bubble { return .colored(color) }
        return .ink
    }

    private func toggleSpeech() {
        guard message.author == .bot else { return }
        if session.speaker.speakingID == message.id {
            session.speaker.stop()
        } else {
            Task { await model.speak(message) }
        }
    }
}

enum BubbleFill {
    case ink
    case colored(Color)
}

/// A chat bubble. Yours is ink, or the Bot's colour when that setting is on; the Bot side is grey.
struct Bubble<Content: View>: View {
    /// Nil for a bubble from the Bot side.
    let fill: BubbleFill?
    let isPending: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(text)
            .tint(text) // links take the text colour: the watch cannot open them
            .background(background, in: .rect(cornerRadius: 15))
            .opacity(isPending ? 0.6 : 1)
            .padding(fill == nil ? .trailing : .leading, 16)
    }

    private var background: Color {
        switch fill {
        case .ink: Theme.ink
        case .colored(let color): color
        case nil: Theme.surface
        }
    }

    private var text: Color {
        if case .ink = fill { Theme.onInk } else { .white }
    }
}

struct MarkdownText: View {
    let markdown: String
    init(_ markdown: String) { self.markdown = markdown }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        Text((try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown))
            .font(.footnote)
    }
}

private struct TypingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis").symbolEffect(.variableColor.iterative)
            Text(text).lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A photo, decoded as a thumbnail: a full-size photo can be tens of MB of bitmap, enough to get a watch app killed.
private struct AttachmentImage: View {
    let path: String
    let caption: String?
    let model: ChatModel
    @State private var image: CGImage?
    @State private var isMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let image {
                    Image(image, scale: 1, label: Text("Photo")).resizable().scaledToFit()
                } else if isMissing {
                    placeholder
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .clipShape(.rect(cornerRadius: 12))
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .task {
            // 2 pixels per point of screen width is sharp on every watch.
            let maxPixelSize = min(800, Int(2 * WKInterfaceDevice.current().screenBounds.width))
            if let url = await model.imageURL(for: path), let data = try? await URLSession.shared.data(from: url).0 {
                image = await Self.thumbnail(of: data, maxPixelSize: maxPixelSize)
            }
            isMissing = image == nil
        }
    }

    private var placeholder: some View {
        Label("Photo", systemImage: "photo").font(.footnote).foregroundStyle(.secondary)
    }

    /// Off the main actor: decoding a large photo takes a while.
    @concurrent private static func thumbnail(of data: Data, maxPixelSize: Int) async -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: NSNumber(value: maxPixelSize),
        ] as [CFString: NSNumber] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// The phone's composer, fitted to a watch: plus for a quick reply, the field for dictation, Scribble or the keyboard.
private struct Composer: View {
    let bot: Bot
    let send: (String) -> Void
    @State private var isShowingReplies = false

    private static let quickReplies = ["Yes", "No", "Go ahead", "Not now", "Thanks"]

    var body: some View {
        HStack(spacing: 5) {
            Button { isShowingReplies = true } label: {
                Image(systemName: "plus").font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(Theme.control, in: Circle())
            }
            .accessibilityLabel("Quick replies")
            TextFieldLink(prompt: Text("Ask \(bot.displayParts.name)")) {
                HStack(spacing: 4) {
                    Text("Ask \(bot.displayParts.name)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "mic.fill").font(.caption2)
                        .frame(width: 22, height: 22)
                        .background(Theme.control, in: Circle())
                }
                .padding(.leading, 11)
                .padding(.trailing, 5)
                .frame(height: 32)
                .background(Theme.control, in: Capsule())
            } onSubmit: { text in
                send(text)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .background(.black)
        .sheet(isPresented: $isShowingReplies) {
            List {
                // The Bot's own suggestions first, then short answers that fit most questions.
                ForEach(bot.suggestions, id: \.id) { suggestion in
                    Button(suggestion.title) { pick(suggestion.prompt) }
                }
                ForEach(Self.quickReplies, id: \.self) { reply in
                    Button(reply) { pick(reply) }
                }
            }
        }
    }

    private func pick(_ text: String) {
        isShowingReplies = false
        send(text)
    }
}

/// Long-press menu: react, or read aloud.
private struct MessageActions: View {
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let model: ChatModel
    private static let emojis = ["👍", "❤️", "😂", "✅", "👀", "🙏"]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 6) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button(emoji) {
                            dismiss()
                            Task { await model.react(to: message, with: emoji) }
                        }
                        .font(.title3)
                    }
                }
                if message.spokenText != nil {
                    Button {
                        dismiss()
                        Task { await model.speak(message) }
                    } label: {
                        Label("Read aloud", systemImage: "speaker.wave.2")
                    }
                }
            }
        }
    }
}
