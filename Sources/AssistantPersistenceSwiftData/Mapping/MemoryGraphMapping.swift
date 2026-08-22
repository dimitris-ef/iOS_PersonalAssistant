#if canImport(SwiftData)

import AssistantDomain
import Foundation
import PersonalMemory
import SwiftData

/// `MemoryRelation` ↔ `SDMemoryRelation`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum MemoryRelationMapper {
    static let entity = "memory-relation"

    static func makeRow(from relation: MemoryRelation) -> SDMemoryRelation {
        SDMemoryRelation(
            id: relation.id.rawValue,
            sourceID: relation.source.rawValue,
            targetID: relation.target.rawValue,
            typeRaw: relation.type.rawValue,
            confidence: relation.confidence,
            createdAt: relation.createdAt
        )
    }

    static func update(_ row: SDMemoryRelation, from relation: MemoryRelation) {
        row.sourceID = relation.source.rawValue
        row.targetID = relation.target.rawValue
        row.typeRaw = relation.type.rawValue
        row.confidence = relation.confidence
        row.createdAt = relation.createdAt
    }

    /// Nil for a relation type this build does not know.
    ///
    /// Dropped rather than defaulted, unlike a memory's source. An unknown
    /// *edge* is safe to ignore — the memories it joins are still there and
    /// still retrievable — whereas guessing at its meaning would let a future
    /// relation type behave like `relatedTo` and quietly boost the wrong things.
    static func makeDomain(from row: SDMemoryRelation) -> MemoryRelation? {
        guard let type = MemoryRelationType(rawValue: row.typeRaw) else { return nil }
        return MemoryRelation(
            source: MemoryItem.ID(row.sourceID),
            target: MemoryItem.ID(row.targetID),
            type: type,
            confidence: row.confidence,
            createdAt: row.createdAt
        )
    }
}

/// `MemoryEmbedding` ↔ `SDMemoryEmbedding`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum MemoryEmbeddingMapper {
    static func makeRow(from embedding: MemoryEmbedding) -> SDMemoryEmbedding {
        SDMemoryEmbedding(
            memoryID: embedding.memoryID,
            vector: embedding.vector.encoded,
            dimension: embedding.vector.dimension,
            encoderProviderID: embedding.encoder.providerID,
            encoderVersion: embedding.encoder.version,
            contentHash: embedding.contentHash,
            createdAt: embedding.createdAt
        )
    }

    static func update(_ row: SDMemoryEmbedding, from embedding: MemoryEmbedding) {
        row.vector = embedding.vector.encoded
        row.dimension = embedding.vector.dimension
        row.encoderProviderID = embedding.encoder.providerID
        row.encoderVersion = embedding.encoder.version
        row.contentHash = embedding.contentHash
        row.createdAt = embedding.createdAt
    }

    /// Nil for a payload that will not decode, or whose length disagrees with
    /// the dimension recorded beside it.
    ///
    /// Treated as a cache miss rather than an error, which is the whole benefit
    /// of the vector being derived data: a corrupt row costs one recomputation.
    /// A vector silently truncated to the wrong length would cost correct
    /// ranking, quietly, forever.
    static func makeDomain(from row: SDMemoryEmbedding) -> MemoryEmbedding? {
        guard
            let vector = SemanticVector.decoded(row.vector),
            vector.dimension == row.dimension,
            !vector.isEmpty
        else { return nil }

        return MemoryEmbedding(
            memoryID: row.memoryID,
            vector: vector,
            encoder: SemanticEncoderIdentity(
                providerID: row.encoderProviderID,
                version: row.encoderVersion
            ),
            contentHash: row.contentHash,
            createdAt: row.createdAt
        )
    }
}

#endif
