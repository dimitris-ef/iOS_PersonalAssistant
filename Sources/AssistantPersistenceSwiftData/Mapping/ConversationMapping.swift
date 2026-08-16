#if canImport(SwiftData)

import AssistantDomain
import Foundation
import SwiftData

/// `Conversation` ↔ `SDConversation`, and `Message` ↔ `SDMessage`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum ConversationMapper {
    static let entity = "conversation"

    static func makeRow(from conversation: Conversation) -> SDConversation {
        SDConversation(
            id: conversation.id.rawValue,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )
    }

    static func updateScalars(_ row: SDConversation, from conversation: Conversation) {
        row.title = conversation.title
        row.createdAt = conversation.createdAt
        row.updatedAt = conversation.updatedAt
    }

    /// Reconciles the stored messages with the ones the domain value carries.
    ///
    /// A conversation is saved whole — the engine appends to the value and
    /// hands the result back — so this diffs by message id rather than
    /// replacing the set. Appending one message therefore inserts one row, and
    /// the identifiers of the messages already stored stay put, which matters
    /// because `Message.actionPlanID` and the action-plan rows point at them.
    ///
    /// Messages absent from the value are deleted: an edit that removes a
    /// message is a real edit, and leaving the row behind would resurrect it on
    /// the next load.
    static func reconcileMessages(
        _ row: SDConversation,
        from conversation: Conversation,
        in context: ModelContext
    ) {
        var existing: [UUID: SDMessage] = [:]
        for message in row.messages {
            existing[message.id] = message
        }

        var kept: Set<UUID> = []
        for (index, message) in conversation.messages.enumerated() {
            kept.insert(message.id.rawValue)

            if let found = existing[message.id.rawValue] {
                found.roleRaw = message.role.rawValue
                found.text = message.text
                found.createdAt = message.createdAt
                found.actionPlanID = message.actionPlanID?.rawValue
                found.sequence = index
            } else {
                let inserted = SDMessage(
                    id: message.id.rawValue,
                    roleRaw: message.role.rawValue,
                    text: message.text,
                    createdAt: message.createdAt,
                    actionPlanID: message.actionPlanID?.rawValue,
                    sequence: index
                )
                inserted.conversation = row
                context.insert(inserted)
            }
        }

        for (id, message) in existing where !kept.contains(id) {
            context.delete(message)
        }
    }

    static func makeDomain(from row: SDConversation) throws -> Conversation {
        // Ordering is defined here, not left to the database. Timestamp first
        // because that is the domain's order; `sequence` breaks ties, which
        // messages written in the same instant will have.
        let ordered = row.messages.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt
                ? lhs.sequence < rhs.sequence
                : lhs.createdAt < rhs.createdAt
        }

        return Conversation(
            id: Conversation.ID(row.id),
            title: row.title,
            messages: try ordered.map(makeMessage),
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    private static func makeMessage(from row: SDMessage) throws -> Message {
        Message(
            id: Message.ID(row.id),
            role: try decodeEnum(MessageRole.self, from: row.roleRaw, entity: "message", field: "role"),
            text: row.text,
            createdAt: row.createdAt,
            actionPlanID: row.actionPlanID.map { ActionPlanID($0) }
        )
    }
}

#endif
