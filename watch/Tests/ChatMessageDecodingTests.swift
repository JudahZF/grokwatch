import Foundation
import Testing
@testable import GrokWatch

/// Transcript entry bodies are undocumented JSON that the vendor can change at any time.
/// One fixture per kind the chat shows, so a format change fails here first.
struct ChatMessageDecodingTests {
    private func entry(_ kind: String, _ json: String) -> TranscriptEntry {
        var entry = TranscriptEntry()
        entry.entryID = "entry-1"
        entry.seq = 7
        entry.entryKind = kind
        entry.body = Data(json.utf8)
        return entry
    }

    private func decode(_ kind: String, _ json: String) throws -> ChatMessage {
        try #require(ChatMessage(entry: entry(kind, json)))
    }

    @Test func ownMessageUsesClientNonce() throws {
        let message = try decode("message", #"{"role":"user","content":"Hi","clientNonce":"nonce-1","timestampMs":1700000000000}"#)
        #expect(message.author == .me)
        #expect(message.id == "nonce-1")
        #expect(message.entryID == "entry-1")
        #expect(message.seq == 7)
        #expect(message.content == .text("Hi"))
        #expect(message.sentAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func snakeCaseKeysDecodeLikeCamelCase() throws {
        let camel = try decode("message", #"{"role":"user","content":"Hi","clientNonce":"nonce-1","timestampMs":1700000000000}"#)
        let snake = try decode("message", #"{"role":"user","content":"Hi","client_nonce":"nonce-1","timestamp_ms":1700000000000}"#)
        #expect(snake == camel)
    }

    @Test func botText() throws {
        let message = try decode("send-message", #"{"message":{"type":"text","content":"Hello"}}"#)
        #expect(message.author == .bot)
        #expect(message.id == "entry-1")
        #expect(message.content == .text("Hello"))
    }

    @Test func openQuestion() throws {
        let message = try decode("send-message", #"""
            {"message":{"type":"widget","widget":{"prompt":"Pick one","helpText":"Any is fine",
            "options":[{"label":"Apple","value":"apple"},{"label":"Pear"}]}}}
            """#)
        let expected = Question(
            prompt: "Pick one", help: "Any is fine",
            options: [.init(label: "Apple", value: "apple"), .init(label: "Pear", value: "Pear")],
            state: .open
        )
        #expect(message.content == .question(expected))
        #expect(message.needsAnswer)
    }

    @Test func answeredQuestion() throws {
        let message = try decode("send-message", #"""
            {"respondedValue":"apple","message":{"type":"widget","widget":{"prompt":"Pick one",
            "options":[{"label":"Apple","value":"apple"}]}}}
            """#)
        guard case .question(let question) = message.content else {
            Issue.record("Expected a question, got \(message.content)")
            return
        }
        #expect(question.state == .answered("apple"))
        #expect(question.answerLabel == "Apple")
        #expect(!message.needsAnswer)
    }

    @Test func pendingApprovalNeedsAnswer() throws {
        let message = try decode("send-message", #"""
            {"message":{"type":"auto-review-approval","approval":{"requestId":"req-1","summary":"Run ls",
            "reason":"List files","command":"ls","status":"pending"}}}
            """#)
        let expected = Approval(requestID: "req-1", summary: "Run ls", reason: "List files", command: "ls", status: "pending")
        #expect(message.content == .approval(expected))
        #expect(message.needsAnswer)
    }

    @Test func approvedApprovalIsDone() throws {
        let message = try decode("send-message", #"""
            {"message":{"type":"auto-review-approval","approval":{"requestId":"req-1","summary":"Run ls","status":"approved"}}}
            """#)
        #expect(!message.needsAnswer)
    }

    @Test func emailDraftHeadingNamesFirstRecipient() throws {
        let message = try decode("send-message", #"""
            {"message":{"type":"email-draft","draft":{"to":["ada@example.com","bob@example.com"],"subject":"Lunch","body":"Noon?"}}}
            """#)
        guard case .draft(let draft) = message.content else {
            Issue.record("Expected a draft, got \(message.content)")
            return
        }
        #expect(draft.heading == "Email to ada@example.com +1")
        #expect(draft.subject == "Lunch")
        #expect(draft.body == "Noon?")
        #expect(draft.state == "editable")
        #expect(message.needsAnswer)
    }

    /// The Send confirmation shows these lines, so every address must be in them.
    @Test func emailDraftAddressLinesNameEveryone() throws {
        let message = try decode("send-message", #"""
            {"message":{"type":"email-draft","draft":{"from":"me@example.com","to":["ada@example.com","bob@example.com"],
            "cc":["cy@example.com"],"body":"Noon?"}}}
            """#)
        guard case .draft(let draft) = message.content else {
            Issue.record("Expected a draft, got \(message.content)")
            return
        }
        let lines = draft.addressLines.joined(separator: "\n")
        for address in ["me@example.com", "ada@example.com", "bob@example.com", "cy@example.com"] {
            #expect(lines.contains(address))
        }
    }

    @Test func slackDraftAddressLinesSayThread() throws {
        let message = try decode("send-message", #"""
            {"message":{"type":"slack-draft","draft":{"workspace":"Acme","target":"#general","thread":"1700000000.0001","body":"Done"}}}
            """#)
        guard case .draft(let draft) = message.content else {
            Issue.record("Expected a draft, got \(message.content)")
            return
        }
        #expect(draft.addressLines == ["Workspace: Acme", "To: #general", "Reply in a thread"])
    }

    @Test func userForm() throws {
        let message = try decode("send-message", #"""
            {"message":{"type":"user-form","formRequest":{"title":"Sign up","instruction":"Your work email",
            "fields":[{"id":"email","label":"Email","type":"email","required":true},{"id":"code","type":"otp"}]}}}
            """#)
        let expected = UserForm(
            title: "Sign up", instruction: "Your work email",
            fields: [
                .init(id: "email", label: "Email", type: "email", isRequired: true, defaultValue: ""),
                .init(id: "code", label: "code", type: "otp", isRequired: false, defaultValue: ""),
            ],
            isOpen: true
        )
        #expect(message.content == .form(expected))
        #expect(message.needsAnswer)
    }

    @Test func attachmentWithWidthIsImage() throws {
        let message = try decode("send-message", #"{"message":{"type":"attachment","url":"files/cat.png","width":640,"alt":"A cat"}}"#)
        #expect(message.content == .image(path: "files/cat.png", caption: "A cat"))
    }

    @Test func attachmentWithoutWidthIsFile() throws {
        let message = try decode("send-message", #"{"message":{"type":"attachment","url":"files/report.pdf","fileName":"report.pdf"}}"#)
        #expect(message.content == .file(name: "report.pdf"))
    }

    // A detail field with another JSON type than guessed must not hide the message.

    @Test func floatWidthIsStillImage() throws {
        let message = try decode("send-message", #"{"message":{"type":"attachment","url":"files/cat.png","width":390.5}}"#)
        #expect(message.content == .image(path: "files/cat.png", caption: nil))
    }

    @Test func nonStringRespondedValueStillAnswers() throws {
        let message = try decode("send-message", #"""
            {"respondedValue":{"choice":"apple"},"message":{"type":"widget","widget":{"prompt":"Pick one",
            "options":[{"label":"Apple","value":"apple"}]}}}
            """#)
        guard case .question(let question) = message.content else {
            Issue.record("Expected a question, got \(message.content)")
            return
        }
        #expect(question.state != .open)
        #expect(question.answerLabel == nil) // the card then reads "Answered", not an empty label
        #expect(!message.needsAnswer)
    }

    @Test func stringTimestampGivesNoTime() throws {
        let message = try decode("send-message", #"{"timestampMs":"1700000000000","message":{"type":"text","content":"Hello"}}"#)
        #expect(message.content == .text("Hello"))
        #expect(message.sentAt == nil)
    }

    @Test func malformedReactionsGiveNone() throws {
        let message = try decode("send-message", #"{"reactions":{"emoji":"👍"},"message":{"type":"text","content":"Hello"}}"#)
        #expect(message.content == .text("Hello"))
        #expect(message.reactions.isEmpty)
    }

    @Test func malformedPayloadOfAnotherTypeKeepsText() throws {
        let message = try decode("send-message", #"{"message":{"type":"text","content":"Hello","draft":5}}"#)
        #expect(message.content == .text("Hello"))
    }

    /// A draft whose state cannot be read may be sent already, so it must not offer Send again.
    @Test func draftWithUnreadableStateIsNotEditable() throws {
        let message = try decode("send-message", #"""
            {"draftSendState":{"status":"sent"},"message":{"type":"email-draft","draft":{"to":["ada@example.com"],"body":"Noon?"}}}
            """#)
        guard case .draft(let draft) = message.content else {
            Issue.record("Expected a draft, got \(message.content)")
            return
        }
        #expect(!draft.isEditable)
        #expect(!message.needsAnswer)
    }

    @Test func approvalWithoutRequestIDIsHidden() {
        let json = #"{"message":{"type":"auto-review-approval","approval":{"summary":"Run ls","status":"pending"}}}"#
        #expect(ChatMessage(entry: entry("send-message", json)) == nil)
    }

    @Test func notice() throws {
        let message = try decode("notice", #"{"text":"Bot restarted"}"#)
        #expect(message.author == .system)
        #expect(message.content == .notice("Bot restarted"))
    }

    @Test func unknownKindIsHidden() {
        #expect(ChatMessage(entry: entry("tool-call", #"{"text":"ls"}"#)) == nil)
    }

    @Test func omittedBodyShowsPlaceholder() throws {
        var omitted = TranscriptEntry()
        omitted.entryID = "entry-2"
        omitted.entryKind = "send-message"
        omitted.bodyOmitted = true
        let message = try #require(ChatMessage(entry: omitted))
        #expect(message.author == .bot)
        #expect(message.content == .text("_Long message. Open Grok Bot on your phone._"))
    }
}
