#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory
import SwiftData

/// `MemoryRelationRepository`, backed by SwiftData.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataMemoryRelationRepository: MemoryRelationRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func save(_ relations: [MemoryRelation]) async throws {
        guard !relations.isEmpty else { return }
        try await persistence.mutate(entity: MemoryRelationMapper.entity) { context in
            for relation in relations {
                let id = relation.id.rawValue
                // Update-or-insert on the derived identity. This is the line
                // that makes running maintenance twice a no-op rather than a
                // way to double every edge in the graph.
                if let existing = try context.first(
                    FetchDescriptor<SDMemoryRelation>(predicate: #Predicate { $0.id == id }),
                    entity: MemoryRelationMapper.entity
                ) {
                    MemoryRelationMapper.update(existing, from: relation)
                } else {
                    context.insert(MemoryRelationMapper.makeRow(from: relation))
                }
            }
        }
    }

    public func relations(for memoryID: MemoryItem.ID) async throws -> [MemoryRelation] {
        let raw = memoryID.rawValue
        return try await persistence.read { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDMemoryRelation>(
                    predicate: #Predicate { $0.sourceID == raw || $0.targetID == raw }
                ),
                entity: MemoryRelationMapper.entity
            )
            return rows.compactMap(MemoryRelationMapper.makeDomain)
        }
    }

    public func all() async throws -> [MemoryRelation] {
        try await persistence.read { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDMemoryRelation>(),
                entity: MemoryRelationMapper.entity
            )
            return rows.compactMap(MemoryRelationMapper.makeDomain)
        }
    }

    public func deleteRelations(touching memoryID: MemoryItem.ID) async throws {
        let raw = memoryID.rawValue
        try await persistence.mutate(entity: MemoryRelationMapper.entity) { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDMemoryRelation>(
                    predicate: #Predicate { $0.sourceID == raw || $0.targetID == raw }
                ),
                entity: MemoryRelationMapper.entity
            )
            for row in rows {
                context.delete(row)
            }
        }
    }
}

/// `MemoryEmbeddingStore`, backed by SwiftData.
///
/// Persisted rather than kept in memory because the alternative is re-encoding
/// every memory a real user has on every cold start — which on a phone is the
/// difference between the first question of the day being answered from memory
/// and being answered without it.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataMemoryEmbeddingStore: MemoryEmbeddingStore {
    private let persistence: AssistantPersistenceActor
    private static let entity = "memory-embedding"

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func embedding(for memoryID: MemoryItem.ID) async throws -> MemoryEmbedding? {
        let raw = memoryID.rawValue
        return try await persistence.read { context in
            guard
                let row = try context.first(
                    FetchDescriptor<SDMemoryEmbedding>(predicate: #Predicate { $0.memoryID == raw }),
                    entity: Self.entity
                )
            else { return nil }
            return MemoryEmbeddingMapper.makeDomain(from: row)
        }
    }

    /// Every cached vector for these memories, in one fetch.
    ///
    /// One round trip rather than one per memory: retrieval asks for the whole
    /// candidate set before ranking, and a per-memory query would put a database
    /// hit inside the loop that runs on every turn.
    public func embeddings(
        for memoryIDs: [MemoryItem.ID]
    ) async throws -> [MemoryItem.ID: MemoryEmbedding] {
        guard !memoryIDs.isEmpty else { return [:] }
        let wanted = Set(memoryIDs.map(\.rawValue))
        return try await persistence.read { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDMemoryEmbedding>(),
                entity: Self.entity
            )
            var found: [MemoryItem.ID: MemoryEmbedding] = [:]
            for row in rows where wanted.contains(row.memoryID) {
                guard let embedding = MemoryEmbeddingMapper.makeDomain(from: row) else { continue }
                found[MemoryItem.ID(row.memoryID)] = embedding
            }
            return found
        }
    }

    public func store(_ embedding: MemoryEmbedding, for memoryID: MemoryItem.ID) async throws {
        let raw = memoryID.rawValue
        try await persistence.mutate(entity: Self.entity) { context in
            if let existing = try context.first(
                FetchDescriptor<SDMemoryEmbedding>(predicate: #Predicate { $0.memoryID == raw }),
                entity: Self.entity
            ) {
                MemoryEmbeddingMapper.update(existing, from: embedding)
            } else {
                context.insert(MemoryEmbeddingMapper.makeRow(from: embedding))
            }
        }
    }

    public func invalidate(memoryID: MemoryItem.ID) async throws {
        let raw = memoryID.rawValue
        try await persistence.mutate(entity: Self.entity) { context in
            guard
                let row = try context.first(
                    FetchDescriptor<SDMemoryEmbedding>(predicate: #Predicate { $0.memoryID == raw }),
                    entity: Self.entity
                )
            else { return }
            context.delete(row)
        }
    }
}

#endif
