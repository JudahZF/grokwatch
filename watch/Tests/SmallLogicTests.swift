import Foundation
import Testing
@testable import GrokWatch

/// Small rules the UI relies on: when a question stops taking answers, and which links open a chat.
struct SmallLogicTests {
    private func question(_ id: String) -> ChatMessage {
        ChatMessage(id: id, entryID: id, seq: 0, author: .bot,
                    content: .question(Question(prompt: "Pick", help: nil, options: [], state: .open)), sentAt: nil)
    }

    private func state(of message: ChatMessage) -> Question.State? {
        guard case .question(let question) = message.content else { return nil }
        return question.state
    }

    /// As on desktop, a question stops taking answers once you send a message after it.
    @Test func settleQuestionsSkipsOnlyQuestionsBeforeYourLatestMessage() {
        let mine = ChatMessage(id: "m", entryID: "m", seq: 0, author: .me, content: .text("Hi"), sentAt: nil)
        var messages = [question("before"), mine, question("after")]
        messages.settleQuestions()
        #expect(state(of: messages[0]) == .skipped)
        #expect(state(of: messages[2]) == .open)
    }

    /// Complication taps open `grokwatch://bot/<agentID>`.
    @Test func deepLinkReadsAgentID() throws {
        #expect(DeepLink.agentID(in: try #require(URL(string: "grokwatch://bot/agent-1"))) == "agent-1")
        #expect(DeepLink.agentID(in: DeepLink.bot("agent-2")) == "agent-2")
    }

    @Test(arguments: ["https://bot/agent-1", "grokwatch://chat/agent-1"])
    func deepLinkRejectsOtherURLs(link: String) throws {
        #expect(DeepLink.agentID(in: try #require(URL(string: link))) == nil)
    }
}
