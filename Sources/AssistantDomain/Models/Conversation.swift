import Foundation

public enum MessageRole: String, Hashable, Codable, Sendable, CaseIterable {
    case user
    case assistant
    /// A short, application-authored note in the transcript (e.g. "reminder
    /// snoozed"). Kept distinct from `assistant` so we never confuse an event
    /// record with something the model actually said.
    case system
}

public struct Message: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<Message>

    public var id: ID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    /// Set on assistant messages that produced an action plan, so the UI can
    /// show what the assistant actually did alongside what it said.
    public var actionPlanID: ActionPlanID?

    public init(
        id: ID = ID(),
        role: MessageRole,
        text: String,
        createdAt: Date,
        actionPlanID: ActionPlanID? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.actionPlanID = actionPlanID
    }
}

/// A thread of messages. Conversations belong to the application, not to any
/// AI provider — swapping providers must never lose them.
public struct Conversation: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<Conversation>

    public var id: ID
    public var title: String?
    public var messages: [Message]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        title: String? = nil,
        messages: [Message] = [],
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public mutating func append(_ message: Message) {
        messages.append(message)
        updatedAt = message.createdAt
    }

    /// The most recent `limit` messages, oldest first.
    public func recentMessages(limit: Int) -> [Message] {
        guard messages.count > limit else { return messages }
        return Array(messages.suffix(limit))
    }
}
