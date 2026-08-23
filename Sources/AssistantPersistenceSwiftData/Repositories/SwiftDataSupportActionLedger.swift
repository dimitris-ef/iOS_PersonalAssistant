#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData

/// `SupportActionLedger`, backed by SwiftData.
///
/// ## Why this has to be persistent
///
/// The duplicate it defends against is not a same-turn one. iOS can hand the
/// app the same notification response again after a crash; a cold launch
/// triggered by a lock-screen "Snooze" can race a foreground reconciliation
/// doing the same work; a user can tap a button on a notification that is
/// already being processed by a process that has since been killed. Every one
/// of those crosses a process boundary, and an in-memory set sees none of them.
///
/// ## Why `claim` is one call
///
/// Read-then-write would be two calls with a gap between them, and the gap is
/// exactly where two callbacks both decide they are the first. The insert is
/// the check: `id` is `@Attribute(.unique)` and derived from (stage, action,
/// revision), so the second insert is refused by the store rather than by a
/// comparison this code has to get right.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataSupportActionLedger: SupportActionLedger {
    static let entity = "handledAction"

    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func claim(_ action: HandledSupportAction) async throws -> Bool {
        let raw = action.id.rawValue
        return try await persistence.mutate(entity: Self.entity) { context in
            let existing = try context.first(
                FetchDescriptor<SDHandledAction>(predicate: #Predicate { $0.id == raw }),
                entity: Self.entity
            )
            guard existing == nil else { return false }
            context.insert(
                SDHandledAction(
                    id: raw,
                    stageID: action.stageID.rawValue,
                    taskID: action.taskID.rawValue,
                    action: action.action,
                    revision: action.revision,
                    handledAt: action.handledAt
                )
            )
            return true
        }
    }

    public func wasHandled(_ id: HandledSupportAction.ID) async throws -> Bool {
        let raw = id.rawValue
        return try await persistence.read { context in
            try context.first(
                FetchDescriptor<SDHandledAction>(predicate: #Predicate { $0.id == raw }),
                entity: Self.entity
            ) != nil
        }
    }

    /// Drops records older than `date`.
    ///
    /// An action from months ago cannot arrive again — the notification that
    /// would have carried it is long gone from the system — so keeping the row
    /// buys nothing and costs a slightly slower launch every time.
    public func prune(before date: Date) async throws {
        try await persistence.mutate(entity: Self.entity) { context in
            let stale = try context.fetchAll(
                FetchDescriptor<SDHandledAction>(
                    predicate: #Predicate { $0.handledAt < date }
                ),
                entity: Self.entity
            )
            for row in stale { context.delete(row) }
        }
    }
}

#endif
