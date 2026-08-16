#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantTools
import Foundation
import SwiftData

/// `ActionPlanRepository`, backed by SwiftData.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataActionPlanRepository: ActionPlanRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    /// Writes the plan, its actions and its results, attached to a conversation.
    ///
    /// The attachment is a relationship rather than a stored id so the cascade
    /// on `SDConversation` reaches it: deleting a conversation removes its
    /// action history with it, and no cleanup code in a view can forget to run.
    public func save(_ record: ActionPlanRecord) async throws {
        let planID = record.plan.id.rawValue
        let conversationID = record.conversationID.rawValue

        try await persistence.mutate(entity: ActionPlanMapper.entity) { context in
            guard
                let conversation = try context.first(
                    FetchDescriptor<SDConversation>(predicate: #Predicate { $0.id == conversationID }),
                    entity: ConversationMapper.entity
                )
            else {
                // A plan with no conversation would be unreachable — nothing
                // else indexes plans — so this is a real failure, not something
                // to write anyway and leave behind.
                throw PersistenceError.entityNotFound(entity: "conversation for this action plan")
            }

            let row: SDActionPlan
            if let existing = try context.first(
                FetchDescriptor<SDActionPlan>(predicate: #Predicate { $0.id == planID }),
                entity: ActionPlanMapper.entity
            ) {
                try ActionPlanMapper.fill(existing, from: record, in: context)
                row = existing
            } else {
                row = try ActionPlanMapper.makeRow(from: record, in: context)
            }
            row.conversation = conversation
        }
    }

    public func record(id: ActionPlanID) async throws -> ActionPlanRecord? {
        let raw = id.rawValue
        return try await persistence.read { context in
            guard
                let row = try context.first(
                    FetchDescriptor<SDActionPlan>(predicate: #Predicate { $0.id == raw }),
                    entity: ActionPlanMapper.entity
                )
            else { return nil }
            return try ActionPlanMapper.makeDomain(from: row)
        }
    }

    public func records(inConversation id: Conversation.ID) async throws -> [ActionPlanRecord] {
        let raw = id.rawValue
        return try await persistence.read { context in
            // Reached through the conversation's own relationship rather than a
            // predicate over it: the relationship is what the cascade uses, so
            // this asks the same question the delete rule answers.
            guard
                let conversation = try context.first(
                    FetchDescriptor<SDConversation>(predicate: #Predicate { $0.id == raw }),
                    entity: ConversationMapper.entity
                )
            else { return [] }

            // Oldest first; the identifier breaks ties, since plans written in
            // the same instant are possible and `UUID` cannot be sorted by the
            // store.
            return try conversation.actionPlans
                .map(ActionPlanMapper.makeDomain)
                .sorted { lhs, rhs in
                    lhs.plan.createdAt == rhs.plan.createdAt
                        ? lhs.plan.id.rawValue.uuidString < rhs.plan.id.rawValue.uuidString
                        : lhs.plan.createdAt < rhs.plan.createdAt
                }
        }
    }
}

#endif
