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

    // MARK: Tools — build 21's "too long" in a brand-new chat

    private func bulkyTools() -> [AIToolSchema] {
        (0..<40).map { index in
            AIToolSchema(
                name: "tool\(index)",
                description: String(repeating: "Describes what this tool does. ", count: 12),
                parameters: .object(properties: [:], required: [])
            )
        }
    }

    func testToolsThatFillTheWindowAreLeftOutAndTheModelIsTold() {
        let request = AIRequest(
            systemPrompt: "You are a helpful assistant.",
            messages: [user("move the dentist appointment to 5")],
            tools: bulkyTools()
        )
        let fitted = ContextWindowFitter.fitDroppingToolsIfNeeded(request, windowTokens: 4096)

        XCTAssertTrue(fitted.droppedTools)
        XCTAssertTrue(fitted.request.tools.isEmpty)
        XCTAssertTrue(fitted.request.systemPrompt.contains("You cannot use tools here"))
        XCTAssertEqual(fitted.request.messages.last?.content, "move the dentist appointment to 5")
    }

    func testToolsThatLeaveRoomAreKept() {
        let request = AIRequest(
            systemPrompt: "Brief.",
            messages: [user("hello")],
            tools: Array(bulkyTools().prefix(2))
        )
        let fitted = ContextWindowFitter.fitDroppingToolsIfNeeded(request, windowTokens: 4096)

        XCTAssertFalse(fitted.droppedTools)
        XCTAssertEqual(fitted.request.tools.count, 2)
        XCTAssertEqual(fitted.request.systemPrompt, "Brief.")
    }

    func testToolsAreNeverTakenAwayHalfwayThroughATurn() {
        let callID = ToolCallID()
        let request = AIRequest(
            systemPrompt: "Brief.",
            messages: [
                user("remind me in 10 minutes"),
                AIMessage(
                    role: .assistant, content: "",
                    toolCalls: [AIToolCall(id: callID, name: "tool0", arguments: .object([:]))]
                ),
                AIMessage(role: .tool, content: "Reminder added.", toolCallID: callID),
            ],
            tools: bulkyTools()
        )
        let fitted = ContextWindowFitter.fitDroppingToolsIfNeeded(request, windowTokens: 4096)

        XCTAssertFalse(fitted.droppedTools)
        XCTAssertEqual(fitted.request.tools.count, request.tools.count)
    }
}
