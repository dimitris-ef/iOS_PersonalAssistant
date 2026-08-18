#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import AssistantTools
import SwiftData
import XCTest

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class ConversationPersistenceTests: PersistenceTestCase {

    // MARK: Save and load

    func testSavesAConversationWithItsMessages() async throws {
        let conversation = makeConversation()
        try await repositories.conversations.save(conversation)

        let loaded = try await repositories.conversations.conversation(id: conversation.id)
        let unwrapped = try XCTUnwrap(loaded)

        XCTAssertEqual(unwrapped.id, conversation.id)
        XCTAssertEqual(unwrapped.title, "Assistant")
        XCTAssertEqual(unwrapped.messages.count, 3)
        XCTAssertEqual(unwrapped.messages.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(unwrapped.messages.map(\.role), [.user, .assistant, .user])
    }

    func testMessageOrderSurvivesAReopen() async throws {
        // Every message shares a timestamp, which is the case a naive
        // implementation gets wrong: with nothing to break the tie, the order
        // becomes whatever the database returns.
        let instant = Self.referenceDate
        let messages = (0..<8).map { index in
            Message(role: index.isMultiple(of: 2) ? .user : .assistant, text: "m\(index)", createdAt: instant)
        }
        let conversation = Conversation(
            title: "Ordering",
            messages: messages,
            createdAt: instant
        )
        try await repositories.conversations.save(conversation)

        try relaunch()

        let stored = try await repositories.conversations.conversation(id: conversation.id)
        let loaded = try XCTUnwrap(stored)
        XCTAssertEqual(loaded.messages.map(\.text), (0..<8).map { "m\($0)" })
        XCTAssertEqual(loaded.messages.map(\.id), messages.map(\.id))
    }

    func testConversationsAreListedMostRecentlyUpdatedFirst() async throws {
        let older = Conversation(
            title: "Older",
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate
        )
        let newer = Conversation(
            title: "Newer",
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate.addingTimeInterval(60)
        )
        try await repositories.conversations.save(older)
        try await repositories.conversations.save(newer)

        let all = try await repositories.conversations.allConversations()
        XCTAssertEqual(all.map(\.title), ["Newer", "Older"])
    }

    // MARK: Updating

    func testAppendingAMessageUpdatesTheSameConversation() async throws {
        var conversation = makeConversation()
        try await repositories.conversations.save(conversation)

        conversation.append(
            Message(
                role: .assistant,
                text: "Fourth",
                createdAt: Self.referenceDate.addingTimeInterval(300)
            )
        )
        try await repositories.conversations.save(conversation)

        try relaunch()

        // One conversation, not two: the second save must have updated the row
        // rather than inserting a copy under the same identifier.
        let all = try await repositories.conversations.allConversations()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.messages.count, 4)
        XCTAssertEqual(all.first?.messages.last?.text, "Fourth")
    }

    func testEditingAMessageOverwritesItRatherThanAddingOne() async throws {
        var conversation = makeConversation()
        try await repositories.conversations.save(conversation)

        conversation.messages[1].text = "Second, corrected"
        try await repositories.conversations.save(conversation)

        try relaunch()

        let stored = try await repositories.conversations.conversation(id: conversation.id)
        let loaded = try XCTUnwrap(stored)
        XCTAssertEqual(loaded.messages.count, 3)
        XCTAssertEqual(loaded.messages[1].text, "Second, corrected")
    }

    func testRemovingAMessageRemovesItFromStorage() async throws {
        var conversation = makeConversation()
        try await repositories.conversations.save(conversation)

        conversation.messages.remove(at: 1)
        try await repositories.conversations.save(conversation)

        try relaunch()

        let stored = try await repositories.conversations.conversation(id: conversation.id)
        let loaded = try XCTUnwrap(stored)
        XCTAssertEqual(loaded.messages.map(\.text), ["First", "Third"])
    }

    // MARK: Deleting

    func testDeletingAConversationRemovesItAndItsMessages() async throws {
        let conversation = makeConversation()
        try await repositories.conversations.save(conversation)
        try await repositories.conversations.delete(id: conversation.id)

        try relaunch()

        let reloaded = try await repositories.conversations.conversation(id: conversation.id)
        let remaining = try await repositories.conversations.allConversations()
        XCTAssertNil(reloaded)
        XCTAssertTrue(remaining.isEmpty)
    }

    /// The messages have to be gone, not merely unreachable.
    ///
    /// Orphaned rows would come back the moment anything fetched messages
    /// directly, and would grow forever. This checks the store, not the
    /// repository's own view of it.
    func testDeletingAConversationLeavesNoOrphanedMessages() async throws {
        let conversation = makeConversation()
        try await repositories.conversations.save(conversation)
        try await repositories.conversations.delete(id: conversation.id)

        try relaunch()

        let persistence = AssistantPersistenceActor(modelContainer: store.container)
        let remaining = try await persistence.read { context in
            try context.fetchCount(FetchDescriptor<SDMessage>())
        }
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Fixtures

    private func makeConversation() -> Conversation {
        Conversation(
            title: "Assistant",
            messages: [
                Message(role: .user, text: "First", createdAt: Self.referenceDate),
                Message(
                    role: .assistant,
                    text: "Second",
                    createdAt: Self.referenceDate.addingTimeInterval(60)
                ),
                Message(
                    role: .user,
                    text: "Third",
                    createdAt: Self.referenceDate.addingTimeInterval(120)
                ),
            ],
            createdAt: Self.referenceDate
        )
    }
}

#endif
