#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData

/// `MemoryRepository`, backed by SwiftData.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataMemoryRepository: MemoryRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func store(_ item: MemoryItem) async throws {
        let id = item.id.rawValue
        try await persistence.mutate(entity: MemoryMapper.entity) { context in
            if let existing = try context.first(Self.descriptor(id: id), entity: MemoryMapper.entity) {
                // Editing a memory rewrites the one that is there. The category
                // goes with it — a memory that changes from a `routine` to a
                // `preference` must not leave the old classification behind.
                MemoryMapper.update(existing, from: item)
            } else {
                context.insert(MemoryMapper.makeRow(from: item))
            }
        }
    }

    public func item(id: MemoryItem.ID) async throws -> MemoryItem? {
        let raw = id.rawValue
        return try await persistence.read { context in
            guard let row = try context.first(Self.descriptor(id: raw), entity: MemoryMapper.entity) else {
                return nil
            }
            return try MemoryMapper.makeDomain(from: row)
        }
    }

    public func all() async throws -> [MemoryItem] {
        try await persistence.read { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDMemory>(
                    sortBy: [SortDescriptor(\SDMemory.createdAt, order: .forward)]
                ),
                entity: MemoryMapper.entity
            )
            // Oldest first, matching the existing repository. The date sort is
            // the store's; the identifier tiebreak is applied here because
            // `UUID` is not `Comparable` and so cannot be a sort descriptor.
            // Without it, memories created in the same instant would come back
            // in whatever order the storage engine chose.
            return try rows.map(MemoryMapper.makeDomain).sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt
                    ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                    : lhs.createdAt < rhs.createdAt
            }
        }
    }

    public func search(_ query: MemoryQuery) async throws -> [MemoryItem] {
        let items = try await all()
        // The same ranking every other backend uses. Keyword overlap and
        // salience are not expressible as a `#Predicate`, and an approximation
        // in SQL that ranked memories differently from the in-memory backend
        // would change what the assistant recalls depending on where it is
        // running.
        return query.rank(items)
    }

    public func delete(id: MemoryItem.ID) async throws {
        let raw = id.rawValue
        try await persistence.mutate(entity: MemoryMapper.entity) { context in
            guard let row = try context.first(Self.descriptor(id: raw), entity: MemoryMapper.entity) else {
                return
            }
            context.delete(row)
        }
    }

    private static func descriptor(id: UUID) -> FetchDescriptor<SDMemory> {
        FetchDescriptor<SDMemory>(predicate: #Predicate { $0.id == id })
    }
}

#endif
