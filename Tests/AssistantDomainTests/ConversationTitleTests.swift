import XCTest

@testable import AssistantDomain

/// The name each chat gets in the chats list.
final class ConversationTitleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_175_200)

    func testAnEmptyChatIsANewChat() {
        XCTAssertEqual(Conversation(createdAt: now).displayTitle, "New chat")
    }

    /// Every chat before build 21 was created titled "Assistant", which names
    /// nothing once there are several.
    func testTheOldPlaceholderTitleGivesWayToTheFirstMessage() {
        var conversation = Conversation(title: "Assistant", createdAt: now)
        conversation.append(Message(role: .assistant, text: "Hi, how can I help?", createdAt: now))
        conversation.append(Message(role: .user, text: "remind me to fix the bottles", createdAt: now))
        XCTAssertEqual(conversation.displayTitle, "remind me to fix the bottles")
    }

    func testARealTitleWins() {
        var conversation = Conversation(title: "Trip planning", createdAt: now)
        conversation.append(Message(role: .user, text: "hello", createdAt: now))
        XCTAssertEqual(conversation.displayTitle, "Trip planning")
    }

    func testALongFirstMessageIsShortened() {
        var conversation = Conversation(createdAt: now)
        conversation.append(
            Message(role: .user, text: String(repeating: "a", count: 100) + "\nsecond line", createdAt: now)
        )
        let title = conversation.displayTitle
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(title.count, Conversation.displayTitleLength + 1)
        XCTAssertFalse(title.contains("second line"))
    }
}
