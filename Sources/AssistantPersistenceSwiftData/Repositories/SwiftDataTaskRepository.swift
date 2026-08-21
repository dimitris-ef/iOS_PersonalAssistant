#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData

/// `TaskRepository`, backed by SwiftData.
///
/// The protocol is unchanged, which is the point: `AssistantEngine` calls
/// `save(_:)` exactly as it did against the in-memory implementation and cannot
/// tell the difference.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataTaskRepository: TaskRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func save(_ task: TaskItem) async throws {
        let id = task.id.rawValue
        try await persistence.mutate(entity: TaskMapper.entity) { context in
            // Update-or-insert, keyed by the domain id. Saving a task twice
            // must leave one task, and completing one must change the row that
            // is already there rather than adding a second, completed copy.
            if let existing = try context.first(Self.descriptor(id: id), entity: TaskMapper.entity) {
                TaskMapper.update(existing, from: task)
            } else {
                context.insert(TaskMapper.makeRow(from: task))
            }
        }
    }

    public func task(id: TaskItem.ID) async throws -> TaskItem? {
        let raw = id.rawValue
        return try await persistence.read { context in
            guard let row = try context.first(Self.descriptor(id: raw), entity: TaskMapper.entity) else {
                return nil
            }
            return try TaskMapper.makeDomain(from: row)
        }
    }

    public func tasks(matching filter: TaskFilter) async throws -> [TaskItem] {
        try await persistence.read { context in
            let rows = try context.fetchAll(FetchDescriptor<SDTask>(), entity: TaskMapper.entity)
            let all = try rows.map(TaskMapper.makeDomain)

            // Filtering and ordering happen in Swift, against the domain
            // values, using the same `TaskFilter.matches` the other backends
            // use. A `#Predicate` could push the status check into the store,
            // but the window check reads `timing.anchorDate`, which is derived
            // from a decomposed enum and has no single column to query. Two
            // implementations of "matches" that could disagree is a worse
            // problem than fetching a few hundred rows.
            let matched = all
                .filter(filter.matches)
                .sorted { lhs, rhs in
                    let left = lhs.anchorDate ?? Date.distantFuture
                    let right = rhs.anchorDate ?? Date.distantFuture
                    // Ties broken by creation order so the list never reorders
                    // itself between two loads of the same data.
                    return left == right ? lhs.createdAt < rhs.createdAt : left < right
                }

            guard let limit = filter.limit else { return matched }
            return Array(matched.prefix(limit))
        }
    }

    public func delete(id: TaskItem.ID) async throws {
        let raw = id.rawValue
        try await persistence.mutate(entity: TaskMapper.entity) { context in
            guard let row = try context.first(Self.descriptor(id: raw), entity: TaskMapper.entity) else {
                return
            }
            context.delete(row)
        }
    }

    private static func descriptor(id: UUID) -> FetchDescriptor<SDTask> {
        FetchDescriptor<SDTask>(predicate: #Predicate { $0.id == id })
    }
}

#endif
