import AssistantDomain
import XCTest

@testable import AssistantAI

/// Build 20: after a few messages Apple's on-device model refused with "That
/// conversation is too long". The history sent to it now fits its window.
final class ContextWindowFitterTests: XCTestCase {

    private func user(_ text: String) -> AIMessage { AIMessage(role: .user, content: text) }
    private func assistant(_ text: String) -> AIMessage { AIMessage(role: .assistant, content: text) }

    /// Forty long exchanges — far beyond 4,096 tokens.
    private func longConversation(endingWith last: String) -> [AIMessage] {
        var messages: [AIMessage] = []
        let filler = String(repeating: "word ", count: 120)
        for index in 0..<40 {
            messages.append(user("question \(index) \(filler)"))
            messages.append(assistant("answer \(index) \(filler)"))
        }
        messages.append(user(last))
        return messages
    }

    private func estimate(_ request: AIRequest) -> Int {
        ContextWindowFitter.estimatedTokens(request.systemPrompt)
            + request.messages.reduce(0) { $0 + ContextWindowFitter.cost(of: $1) }
            + (request.options.maximumOutputTokens ?? ContextWindowFitter.defaultReplyTokens)
    }

    func testALongConversationIsTrimmedToFit() {
        let request = AIRequest(
            systemPrompt: "You are a helpful assistant.",
            messages: longConversation(endingWith: "What now?")
        )
        let fitted = ContextWindowFitter.fit(request, windowTokens: 4096)

        XCTAssertLessThan(fitted.messages.count, request.messages.count)
        XCTAssertLessThanOrEqual(estimate(fitted), 4096)
        XCTAssertEqual(fitted.messages.last?.content, "What now?", "the question is always kept")
        XCTAssertEqual(fitted.messages.first?.role, .user, "history starts at a user message")
        XCTAssertGreaterThan(fitted.messages.count, 1, "recent history is kept when it fits")
    }

    func testAShortConversationIsUntouched() {
        let request = AIRequest(
            systemPrompt: "Brief.",
            messages: [user("hi"), assistant("hello"), user("how are you")]
        )
        XCTAssertEqual(ContextWindowFitter.fit(request, windowTokens: 4096), request)
    }

    /// A continuation round: the tool call and its result belong to the turn
    /// being answered, and are kept even when nothing older fits.
    func testTheCurrentTurnIsNeverSplit() {
        let callID = ToolCallID()
        var messages = longConversation(endingWith: "remind me in 10 minutes")
        messages.append(
            AIMessage(
                role: .assistant, content: "",
                toolCalls: [AIToolCall(id: callID, name: "createReminder", arguments: .object([:]))]
            )
        )
        messages.append(AIMessage(role: .tool, content: "Reminder added.", toolCallID: callID))
        let request = AIRequest(systemPrompt: "Brief.", messages: messages)

        let fitted = ContextWindowFitter.fit(request, windowTokens: 1200)

        XCTAssertEqual(fitted.messages.suffix(3).map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(fitted.messages.first?.role, .user)
    }

    func testNothingToTrimWhenTheOnlyUserMessageIsFirst() {
        let request = AIRequest(
            systemPrompt: String(repeating: "x", count: 20_000),
            messages: [user("hello")]
        )
        XCTAssertEqual(ContextWindowFitter.fit(request, windowTokens: 4096), request)
    }
}
