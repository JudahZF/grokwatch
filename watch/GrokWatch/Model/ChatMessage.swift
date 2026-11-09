import Foundation

/// One chat row, decoded from a transcript entry's JSON body. Kinds follow the desktop's message renderers.
struct ChatMessage: Identifiable, Equatable {
    enum Author { case me, bot, system }

    enum Content: Equatable {
        case text(String)
        case question(Question)
        case approval(Approval)
        case draft(Draft)
        case form(UserForm)
        /// `path` is resolved to a download URL with `ResolveGrokBotAttachmentReads`.
        case image(path: String, caption: String?)
        case file(name: String)
        case notice(String)
        /// A card the watch cannot act on (sign-ins, secrets, connectors). `done` once it is resolved elsewhere.
        case phoneOnly(title: String, detail: String?, done: Bool)
    }

    /// Your messages use their `clientNonce` (= the send `messageID`), so the server echo replaces the pending bubble.
    let id: String
    /// Transcript entry id. Card RPCs and reactions address the entry by this.
    let entryID: String
    var seq: UInt64
    let author: Author
    var content: Content
    let sentAt: Date?
    var reactions: [String] = []
    var isPending = false

    /// What "Read aloud" speaks.
    var spokenText: String? {
        switch content {
        case .text(let text), .notice(let text): text
        case .question(let question): ([question.prompt] + question.options.map(\.label)).joined(separator: ". ")
        case .approval(let approval): "Approval needed. \(approval.summary)"
        case .draft(let draft): [draft.heading, draft.subject, draft.body].compactMap(\.self).joined(separator: ". ")
        case .form(let form): form.title
        case .image, .file, .phoneOnly: nil
        }
    }

    /// Cards that wait for your answer. They show actions until they are answered.
    var needsAnswer: Bool {
        switch content {
        case .question(let question): question.state == .open
        case .approval(let approval): approval.isOpen
        case .draft(let draft): draft.isEditable
        case .form(let form): form.isOpen
        default: false
        }
    }
}

struct Question: Equatable {
    struct Option: Equatable, Hashable {
        let label: String
        /// Sent to the Bot as your answer.
        let value: String
    }
    enum State: Equatable { case open, answered(String), skipped }

    let prompt: String
    let help: String?
    let options: [Option]
    var state: State

    /// The chosen option's label, or the raw answer.
    var answerLabel: String? {
        guard case .answered(let value) = state else { return nil }
        return options.first { $0.value == value }?.label ?? value
    }
}

struct Approval: Equatable {
    let requestID: String
    let summary: String
    let reason: String?
    let command: String?
    /// `pending`, `approved`, `denied`, `expired`, … Only `pending` takes an answer.
    var status: String
    var isOpen: Bool { status == "pending" }
}

struct Draft: Equatable {
    let payload: Aiserver_V1_SendGrokBotDraftRequest.OneOf_Draft
    /// "Email to …" or "Slack to …".
    let heading: String
    let subject: String?
    let body: String
    /// `draftSendState ?? draftSaveState ?? "editable"`, as on desktop.
    var state: String
    var isEditable: Bool { state == "editable" || state == "failed" }
}

struct UserForm: Equatable {
    struct Field: Equatable, Identifiable {
        let id: String
        let label: String
        /// `text`, `email`, `password`, `otp`, …
        let type: String
        let isRequired: Bool
        let defaultValue: String
        var isSecret: Bool { type == "password" || type == "otp" }
    }

    let title: String
    let instruction: String?
    let fields: [Field]
    var isOpen: Bool
}

extension ChatMessage {
    /// Returns nil for entries the chat does not show (tool calls, most events, agent-to-agent traffic).
    init?(entry: TranscriptEntry) {
        let entryID = entry.entryID.isEmpty ? "seq-\(entry.seq)" : entry.entryID
        if entry.bodyOmitted, entry.entryKind == "send-message" {
            self.init(id: entryID, entryID: entryID, seq: entry.seq, author: .bot,
                      content: .text("_Long message. Open Grok Bot on your phone._"), sentAt: nil)
            return
        }
        guard entry.hasBody, let body = try? Self.decoder.decode(EntryBody.self, from: entry.body) else { return nil }
        let sentAt = body.timestampMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        let reactions = body.reactions?.map(\.emoji) ?? []

        func make(_ author: Author, _ content: Content, id: String? = nil) -> ChatMessage {
            ChatMessage(id: id ?? entryID, entryID: entryID, seq: entry.seq, author: author, content: content, sentAt: sentAt, reactions: reactions)
        }

        switch entry.entryKind {
        case "message" where body.role == "user" && body.fromAgent == nil:
            guard let text = body.content, !text.isEmpty else { return nil }
            self = make(.me, .text(text), id: body.clientNonce)
        case "user-attachment":
            guard let path = body.filePath else { return nil }
            self = make(.me, body.width == nil ? .file(name: body.fileName ?? "File") : .image(path: path, caption: nil))
        case "notice":
            guard let text = body.text else { return nil }
            self = make(.system, .notice(text))
        case "event":
            guard let event = body.event, event.type == "automation-changed", let name = event.automationName else { return nil }
            self = make(.system, .notice("\(event.action?.capitalized ?? "Changed") automation “\(name)”"))
        case "send-message":
            guard let message = body.message, let content = Self.content(of: message, in: body) else { return nil }
            self = make(.bot, content)
        default:
            return nil
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func content(of message: EntryBody.Message, in body: EntryBody) -> Content? {
        switch message.type ?? "text" {
        case "text":
            guard let text = message.content, !text.isEmpty else { return nil }
            return .text(text)
        case "widget":
            guard let widget = message.widget else { return nil }
            let state: Question.State =
                if let value = body.respondedValue { .answered(value) }
                else if body.widgetDismissed == true || body.widgetSkipped == true { .skipped } else { .open }
            return .question(Question(
                prompt: widget.prompt ?? "",
                help: widget.helpText,
                options: (widget.options ?? []).map { Question.Option(label: $0.label, value: $0.value ?? $0.label) },
                state: state
            ))
        case "auto-review-approval":
            guard let approval = message.approval else { return nil }
            return .approval(Approval(
                requestID: approval.requestId,
                summary: approval.summary ?? approval.cardDescription ?? "The Bot wants to take an action.",
                reason: approval.reason,
                command: approval.command,
                status: approval.status ?? "pending"
            ))
        case "email-draft", "slack-draft":
            guard let draft = message.draft else { return nil }
            return .draft(Self.draft(draft, isEmail: message.type == "email-draft",
                                     state: body.draftSendState ?? body.draftSaveState ?? "editable"))
        case "user-form":
            guard let form = message.formRequest else { return nil }
            return .form(UserForm(
                title: form.title ?? "Form",
                instruction: form.instruction,
                fields: (form.fields ?? []).map {
                    UserForm.Field(id: $0.id, label: $0.label ?? $0.id, type: $0.type ?? "text",
                               isRequired: $0.required ?? false, defaultValue: $0.defaultValue ?? "")
                },
                isOpen: body.formResolution == nil && body.formSubmissionEffect == nil
            ))
        case "attachment":
            guard let url = message.url else { return nil }
            return message.width == nil ? .file(name: message.fileName ?? "File") : .image(path: url, caption: message.alt)
        case "credential-request":
            return .phoneOnly(title: "Sign-in request", detail: message.credentialRequest?.goal, done: body.credentialResolution != nil)
        case "secret-request":
            return .phoneOnly(title: "Secret request", detail: message.secretRequest?.label, done: body.secretProvided == true)
        case "connector":
            return .phoneOnly(title: "Connect \(message.connector ?? "an app")", detail: nil, done: false)
        case "imessage-draft":
            return .phoneOnly(title: "iMessage draft", detail: message.draft?.body, done: body.draftSendState != nil)
        default:
            return nil
        }
    }

    private static func draft(_ draft: EntryBody.Message.DraftBody, isEmail: Bool, state: String) -> Draft {
        let body = draft.body ?? ""
        if isEmail {
            var email = Aiserver_V1_GrokBotEmailDraft()
            email.from = draft.from ?? ""
            email.to = draft.to ?? []
            email.cc = draft.cc ?? []
            email.subject = draft.subject ?? ""
            email.body = body
            let to = email.to.first.map { email.to.count > 1 ? "\($0) +\(email.to.count - 1)" : $0 } ?? "…"
            return Draft(payload: .email(email), heading: "Email to \(to)", subject: draft.subject, body: body, state: state)
        }
        var slack = Aiserver_V1_GrokBotSlackDraft()
        if let workspace = draft.workspace { slack.workspace = workspace }
        slack.target = draft.target ?? ""
        if let thread = draft.thread { slack.thread = thread }
        slack.body = body
        return Draft(payload: .slack(slack), heading: "Slack to \(slack.target)", subject: nil, body: body, state: state)
    }
}

/// The subset of entry JSON the watch reads. Keys are camelCase or snake_case; the decoder converts snake_case.
private struct EntryBody: Decodable {
    struct Reaction: Decodable { let emoji: String }
    /// Only its presence matters: a `message` from another Bot.
    struct Peer: Decodable {}
    struct Event: Decodable {
        let type: String?
        let action: String?
        let automationName: String?
    }
    struct Message: Decodable {
        struct Widget: Decodable {
            struct Option: Decodable {
                let label: String
                let value: String?
            }
            let prompt: String?
            let helpText: String?
            let options: [Option]?
        }
        struct ApprovalBody: Decodable {
            let requestId: String
            let summary: String?
            let cardDescription: String?
            let reason: String?
            let command: String?
            let status: String?
        }
        struct DraftBody: Decodable {
            let from: String?
            let to: [String]?
            let cc: [String]?
            let subject: String?
            let body: String?
            let workspace: String?
            let target: String?
            let thread: String?
        }
        struct FormBody: Decodable {
            struct Field: Decodable {
                let id: String
                let label: String?
                let type: String?
                let required: Bool?
                let defaultValue: String?
            }
            let title: String?
            let instruction: String?
            let fields: [Field]?
        }
        struct CredentialRequest: Decodable { let goal: String? }
        struct SecretRequest: Decodable { let label: String? }

        let type: String?
        let content: String?
        let widget: Widget?
        let approval: ApprovalBody?
        let draft: DraftBody?
        let formRequest: FormBody?
        let credentialRequest: CredentialRequest?
        let secretRequest: SecretRequest?
        let connector: String?
        let url: String?
        let fileName: String?
        let alt: String?
        let width: Int?
    }
    struct Effect: Decodable { let kind: String? }

    let role: String?
    let content: String?
    let clientNonce: String?
    let fromAgent: Peer?
    let timestampMs: Double?
    let text: String?
    let filePath: String?
    let fileName: String?
    let width: Int?
    let event: Event?
    let message: Message?
    let reactions: [Reaction]?
    let respondedValue: String?
    let widgetSkipped: Bool?
    let widgetDismissed: Bool?
    let draftSendState: String?
    let draftSaveState: String?
    let formResolution: String?
    let formSubmissionEffect: Effect?
    let credentialResolution: String?
    let secretProvided: Bool?
}
