#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 7: semantic memory.
//
// Three additions, one theme — remembering by meaning rather than by wording,
// and keeping the store honest about what it has concluded.
//
//  1. `SDMemory` gains a lifecycle, entity keys, consolidation provenance and a
//     protection flag. A memory is no longer just present or absent: it can be
//     current, fading, archived, superseded by a newer statement, or in an
//     unresolved disagreement — and every one of those stays visible to the user
//     rather than being deleted.
//
//  2. `SDMemoryRelation`, a new entity. Typed edges between memories: what
//     supports what, what refines what, what contradicts what. Six relation
//     types, one hop, no inference — see `MemoryRelationType`.
//
//  3. `SDMemoryEmbedding`, a new entity. The vector cache.
//
// ## Why the vector is a separate entity rather than a column on SDMemory
//
// Because it is derived data with a different lifetime. A vector is invalidated
// by things that do not change the memory — the encoder being upgraded — and
// survives things that do not change it either. As a column it would be loaded
// on every memory fetch the app makes, including the Memory screen's, which
// wants text and never wants a kilobyte of floats. As its own row it is fetched
// only by the one subsystem that uses it.
//
// It is also the only part of this schema that may be thrown away without loss.
// Deleting every embedding row costs a few milliseconds of recomputation and no
// information at all, which is a useful property for a cache to have and not one
// a column on the model would advertise.
//
// ## Why migration does not generate embeddings
//
// Section 105, and it is the right instruction: a schema migration that has to
// encode every memory the user has is a migration that can be slow, can fail
// halfway, and turns a version bump into a data-loss risk. Existing rows migrate
// with no vector, which the cache already treats as "not computed yet", and the
// vectors appear lazily as memories are retrieved and as maintenance runs.
//
// ## Why this stays inferrable
//
// Every added property on `SDMemory` is optional or carries a declared default,
// and the two new models are new entities. That is the case SwiftData infers
// from the store's own metadata — the same reasoning set out in
// `PersonalAssistantSchemaV2`.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV7: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            SDConversation.self,
            SDMessage.self,
            SDActionPlan.self,
            SDAction.self,
            SDToolResult.self,
            SDMemory.self,
            SDMemoryRelation.self,
            SDMemoryEmbedding.self,
            SDTask.self,
            SDRoutine.self,
            SDReminderPlan.self,
            SDReminderStage.self,
            SDAssistantSettings.self,
            SDUserProfile.self,
        ]
    }
}

/// One typed link between two memories.
///
/// The row's own `id` is derived from source, target and type rather than
/// allocated — see `MemoryRelation.identity(source:target:type:)`. That is what
/// makes writing the same edge on every maintenance pass update one row instead
/// of accumulating thousands of identical ones.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDMemoryRelation {
    @Attribute(.unique) public var id: UUID
    public var sourceID: UUID
    public var targetID: UUID
    public var typeRaw: String
    public var confidence: Double
    public var createdAt: Date

    public init(
        id: UUID,
        sourceID: UUID,
        targetID: UUID,
        typeRaw: String,
        confidence: Double,
        createdAt: Date
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.typeRaw = typeRaw
        self.confidence = confidence
        self.createdAt = createdAt
    }
}

/// One cached vector.
///
/// Keyed by the memory it describes, and carrying the two things that decide
/// whether it may still be used: the hash of the text it was computed from, and
/// the identity of the encoder that computed it. Either changing means the
/// vector is stale, and stale means regenerate rather than "close enough" — a
/// vector from a different encoder compared against a current one produces a
/// number that looks like a similarity and is noise.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDMemoryEmbedding {
    /// The memory's identifier. One vector per memory, so this is the key.
    @Attribute(.unique) public var memoryID: UUID
    /// Little-endian float components. See `SemanticVector.encoded`.
    public var vector: Data
    public var dimension: Int
    /// Which encoder, and which version of it.
    public var encoderProviderID: String
    public var encoderVersion: Int
    /// Hash of the normalised content this was computed from.
    public var contentHash: String
    public var createdAt: Date

    public init(
        memoryID: UUID,
        vector: Data,
        dimension: Int,
        encoderProviderID: String,
        encoderVersion: Int,
        contentHash: String,
        createdAt: Date
    ) {
        self.memoryID = memoryID
        self.vector = vector
        self.dimension = dimension
        self.encoderProviderID = encoderProviderID
        self.encoderVersion = encoderVersion
        self.contentHash = contentHash
        self.createdAt = createdAt
    }
}

#endif
