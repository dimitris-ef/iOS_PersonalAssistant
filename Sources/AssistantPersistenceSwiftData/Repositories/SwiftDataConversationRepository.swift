#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData

/// `ConversationRepository`, backed by SwiftData.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataConversationRepository: ConversationRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func conversation(id: Conversation.ID) async throws -> Conversation? {
        let raw = id.rawValue
        return try await persistence.read { context in
            guard
                let row = try context.first(Self.descriptor(id: raw), entity: ConversationMapper.entity)
            else { return nil }
            return try ConversationMapper.makeDomain(from: row)
        }
    }

    public func allConversations() async throws -> [Conversation] {
        try await persistence.read { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDConversation>(
                    sortBy: [SortDescriptor(\SDConversation.updatedAt, order: .reverse)]
                ),
                entity: ConversationMapper.entity
            )
            // Most recently touched first, matching the existing repository,
            // with an identifier tiebreak applied here because `UUID` cannot be
            // a sort descriptor.
            return try rows.map(ConversationMapper.makeDomain).sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt
                    ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                    : lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    /// Writes a conversation and its messages as one unit.
    ///
    /// The conversation row and every message row are inserted or updated
    /// inside a single `mutate`, so one save commits them together: a turn that
    /// appends a message can never leave a conversation whose row says it was
    /// updated but whose message is missing.
    public func save(_ conversation: Conversation) async throws {
        let id = conversation.id.rawValue
        try await persistence.mutate(entity: ConversationMapper.entity) { context in
            let row: SDConversation
            if let existing = try context.first(
                Self.descriptor(id: id), entity: ConversationMapper.entity
            ) {
                ConversationMapper.updateScalars(existing, from: conversation)
                row = existing
            } else {
                let inserted = ConversationMapper.makeRow(from: conversation)
                context.insert(inserted)
                row = inserted
            }
            ConversationMapper.reconcileMessages(row, from: conversation, in: context)
        }
    }

    /// Deletes the conversation, its messages and its action plans.
    ///
    /// The cascade is declared on the relationships in the schema, not
    /// performed here, so nothing depends on this method being the only route
    /// to a delete. Nothing is left orphaned either way.
    public func delete(id: Conversation.ID) async throws {
        let raw = id.rawValue
        try await persistence.mutate(entity: ConversationMapper.entity) { context in
            guard
                let row = try context.first(Self.descriptor(id: raw), entity: ConversationMapper.entity)
            else { return }
            context.delete(row)
        }
    }

    private static func descriptor(id: UUID) -> FetchDescriptor<SDConversation> {
        FetchDescriptor<SDConversation>(predicate: #Predicate { $0.id == id })
    }
}

#endif
