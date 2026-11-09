import SwiftUI

struct ChatView: View {
    @Environment(AppSession.self) private var session
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var actionsFor: ChatMessage?
    @State private var isCalling = false

    init(bot: Bot, session: AppSession) {
        _model = State(initialValue: ChatModel(bot: bot, session: session))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
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
                        MessageRow(message: message, model: model, onLongPress: { actionsFor = message })
                            .id(message.id)
                    }
                    if let activity = model.activity {
                        TypingRow(text: activity).transition(.opacity)
                    }
                    if let status = model.status {
                        Text(status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    // On watchOS, tapping a TextField opens dictation / Scribble / keyboard.
                    TextField("Message", text: $draft)
                        .submitLabel(.send)
                        .onSubmit {
                            let text = draft
                            draft = ""
                            Task { await model.send(text) }
                        }
                        .id("composer")
                }
                .animation(.snappy, value: model.activity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.last?.id) {
                // An open card shows from its top, so its question is visible; anything else scrolls to the composer.
                withAnimation {
                    if let last = model.messages.last, last.needsAnswer {
                        proxy.scrollTo(last.id, anchor: .top)
                    } else {
                        proxy.scrollTo("composer", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle(model.bot.displayParts.name)
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
            Bubble(isMine: message.author == .me, isPending: message.isPending) {
                MarkdownText(text)
                if session.speaker.speakingID == message.id {
                    Image(systemName: "speaker.wave.2.fill").font(.caption2).symbolEffect(.variableColor)
                }
            }
            .onTapGesture { toggleSpeech() }
        case .image(let path, let caption):
            AttachmentImage(path: path, caption: caption, model: model)
        case .file(let name):
            Bubble(isMine: message.author == .me, isPending: false) {
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

    private func toggleSpeech() {
        guard message.author == .bot else { return }
        if session.speaker.speakingID == message.id {
            session.speaker.stop()
        } else {
            Task { await model.speak(message) }
        }
    }
}

struct Bubble<Content: View>: View {
    let isMine: Bool
    let isPending: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray.opacity(0.25)), in: .rect(cornerRadius: 12))
            .opacity(isPending ? 0.6 : 1)
            .padding(isMine ? .leading : .trailing, 16)
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

private struct AttachmentImage: View {
    let path: String
    let caption: String?
    let model: ChatModel
    @State private var url: URL?
    @State private var isMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else if phase.error != nil {
                            placeholder
                        } else {
                            ProgressView()
                        }
                    }
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
            url = await model.imageURL(for: path)
            isMissing = url == nil
        }
    }

    private var placeholder: some View {
        Label("Photo", systemImage: "photo").font(.footnote).foregroundStyle(.secondary)
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
