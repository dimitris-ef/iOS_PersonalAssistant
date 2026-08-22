import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory

/// What happened when a memory was offered to the store.
public struct MemoryWriteResult: Sendable {
    public enum Effect: Hashable, Sendable {
        case stored
        /// Folded into an existing record; no second row.
        case merged(into: MemoryItem.ID)
        /// An existing record was corrected.
        case replaced(MemoryItem.ID)
        /// Kept alongside a memory it disagrees with.
        case keptAlongsideConflict(with: MemoryItem.ID)
    }

    public var memory: MemoryItem
    public var effect: Effect
    /// One line for the user or the transcript.
    public var summary: String

    public init(memory: MemoryItem, effect: Effect, summary: String) {
        self.memory = memory
        self.effect = effect
        self.summary = summary
    }
}

/// The one way a memory gets written.
///
/// Deduplication has to live behind a single door or it does not exist: put it
/// in the `storeMemory` tool and the Memory screen creates duplicates; put it
/// in the screen and the assistant does. Both go through here.
///
/// Separate from retrieval on purpose. Writing is about trust, duplication and
/// conflict; reading is about relevance and budget. They change for different
/// reasons and share nothing but the repository.
public struct MemoryService: Sendable {
    private let repository: any MemoryRepository
    private let relations: (any MemoryRelationRepository)?
    private let embeddings: (any MemoryEmbeddingStore)?
    private let encoder: (any SemanticEncoder)?
    private let deduplicator: MemoryDeduplicator
    private let dateProvider: any DateProvider

    public init(
        repository: any MemoryRepository,
        relations: (any MemoryRelationRepository)? = nil,
        embeddings: (any MemoryEmbeddingStore)? = nil,
        encoder: (any SemanticEncoder)? = nil,
        deduplicator: MemoryDeduplicator = MemoryDeduplicator(),
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.repository = repository
        self.relations = relations
        self.embeddings = embeddings
        self.encoder = encoder
        self.deduplicator = deduplicator
        self.dateProvider = dateProvider
    }

    /// Offers a memory to the store, deduplicating and resolving conflicts.
    @discardableResult
    public func remember(_ candidate: MemoryItem) async throws -> MemoryWriteResult {
        let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MemoryServiceError.emptyContent
        }

        var candidate = candidate
        candidate.content = content
        // Derived here, once, so every path below — duplicate detection,
        // conflict detection, consolidation later — sees the same handles.
        if candidate.entityKeys.isEmpty {
            candidate.entityKeys = MemoryEntityExtractor.keys(
                for: candidate.content,
                kind: candidate.kind
            )
        }

        let now = dateProvider.now
        // Superseded and archived memories take no part in duplicate detection.
        // A new statement of a fact must not be folded into the *old* answer to
        // it, which is exactly what comparing against superseded rows would do.
        let existing = try await repository.all().filter { $0.lifecycle != .superseded }

        // Vectors for the memories being compared against, when there are any.
        // Missing ones simply leave that comparison lexical — the same fallback
        // retrieval uses, for the same reason.
        let vectors = await self.vectors(for: existing + [candidate])

        switch deduplicator.classify(candidate, against: existing, vectors: vectors) {
        case .distinct:
            try await repository.store(candidate)
            await refreshEmbedding(for: candidate)
            return MemoryWriteResult(
                memory: candidate,
                effect: .stored,
                summary: "Remembered: \(candidate.content)"
            )

        case .exactDuplicate(let stored), .nearDuplicate(let stored, _):
            // Already known. Refresh it rather than accumulating a second copy
            // of the same fact — the Memory screen is something the user reads.
            let merged = deduplicator.merged(stored, with: candidate, at: now)
            try await repository.store(merged)
            await refreshEmbedding(for: merged)
            return MemoryWriteResult(
                memory: merged,
                effect: .merged(into: merged.id),
                summary: "Already knew that: \(merged.content)"
            )

        case .conflicting(let stored, _):
            switch deduplicator.resolution(existing: stored, candidate: candidate) {
            case .replaceContent:
                var corrected = stored
                corrected.content = candidate.content
                corrected.kind = candidate.kind
                corrected.source = candidate.source
                corrected.confidence = candidate.confidence
                corrected.salience = max(stored.salience, candidate.salience)
                corrected.tags = Array(Set(stored.tags).union(candidate.tags)).sorted()
                corrected.updatedAt = now
                corrected.entityKeys = Array(
                    Set(stored.entityKeys).union(candidate.entityKeys)
                ).sorted()
                // The newer statement wins outright, so this record now *is*
                // the current answer and stays active. The old wording is gone
                // from this row — but the row is the same row, so nothing that
                // referred to the fact has been orphaned.
                corrected.lifecycle = .active
                try await repository.store(corrected)
                await refreshEmbedding(for: corrected)
                return MemoryWriteResult(
                    memory: corrected,
                    effect: .replaced(corrected.id),
                    summary: "Updated what I knew: \(corrected.content)"
                )

            case .keepBoth:
                // Weaker evidence than what is already stored. Keeping both
                // leaves the disagreement visible in the Memory screen, where
                // the user can settle it, rather than silently overwriting
                // something they said with something the assistant guessed.
                //
                // Marked `conflicting` rather than active, which is the part
                // Part 9 adds: the disagreement is now a state the store knows
                // about, so retrieval can keep the weaker claim out of prompts
                // while the Memory screen still shows both. A `contradicts`
                // edge records which memory it disagrees with, so the screen can
                // show them together instead of as two unexplained rows.
                var conflicted = candidate
                conflicted.lifecycle = .conflicting
                try await repository.store(conflicted)
                await refreshEmbedding(for: conflicted)
                try? await relations?.save([
                    MemoryRelation(
                        source: conflicted.id,
                        target: stored.id,
                        type: .contradicts,
                        confidence: 0.7,
                        createdAt: now
                    )
                ])
                return MemoryWriteResult(
                    memory: conflicted,
                    effect: .keptAlongsideConflict(with: stored.id),
                    summary: "Remembered, though it disagrees with something I already knew: "
                        + conflicted.content
                )
            }
        }
    }

    /// Applies a user's edit.
    ///
    /// Authoritative and never deduplicated: the user is looking at this exact
    /// record and changing it. Running it through duplicate detection could
    /// fold their edit into a different memory, which from their side would
    /// look like the app refusing to save.
    @discardableResult
    public func update(_ memory: MemoryItem) async throws -> MemoryItem {
        let content = memory.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw MemoryServiceError.emptyContent }

        let previous = try? await repository.item(id: memory.id)

        var updated = memory
        updated.content = content
        updated.updatedAt = dateProvider.now
        updated.source = .manual
        updated.confidence = MemorySource.manual.defaultConfidence
        // An edit is the strongest statement of interest the app ever gets, so
        // it takes the memory out of maintenance's hands: consolidation will not
        // rewrite it from the sources it once summarised, and aging will not
        // fade it. Section 99 and section 41 are the same rule seen from two
        // sides — the user's wording is authoritative and stays that way.
        updated.isProtected = true
        // Editing brings a memory back. Correcting an archived or superseded
        // fact plainly means the user wants it to count again, and leaving it in
        // a state that excludes it from retrieval would make their correction
        // do nothing.
        updated.lifecycle = .active
        updated.entityKeys = MemoryEntityExtractor.keys(for: content, kind: updated.kind)
        try await repository.store(updated)

        // The vector describes text that no longer exists. Dropped first and
        // regenerated second, so a failure between the two leaves no vector
        // rather than a wrong one — retrieval treats a missing vector as "rank
        // on words" and a wrong one as truth.
        if previous?.content != content {
            try? await embeddings?.invalidate(memoryID: updated.id)
        }
        await refreshEmbedding(for: updated)

        // Anything this memory used to contradict is now contradicting
        // different words. The edge itself still holds — the user corrected one
        // side of a disagreement, they did not resolve it — but a `supports`
        // edge into a consolidated fact does not: this wording is no longer the
        // evidence that fact was built from.
        try? await relations?.save(await staleSupportEdges(for: updated))

        return updated
    }

    /// Removes a memory and everything derived from it.
    ///
    /// Section 52: the user's delete wins, and it wins completely. The vector
    /// goes, the edges go, and nothing may put the memory back — which is why
    /// consolidation reads the repository rather than a cache of its own.
    public func forget(id: MemoryItem.ID) async throws {
        try await repository.delete(id: id)
        try? await embeddings?.invalidate(memoryID: id)
        try? await relations?.deleteRelations(touching: id)
    }

    /// Brings an archived or stale memory back into use.
    ///
    /// The user asking for it back is explicit interest, so the memory returns
    /// protected: whatever aging concluded about it, they have now said
    /// otherwise, and the next maintenance pass must not quietly re-archive it.
    @discardableResult
    public func restore(id: MemoryItem.ID) async throws -> MemoryItem {
        guard var memory = try await repository.item(id: id) else {
            throw MemoryServiceError.notFound
        }
        memory.lifecycle = .active
        memory.isProtected = true
        memory.updatedAt = dateProvider.now
        try await repository.store(memory)
        await refreshEmbedding(for: memory)
        return memory
    }

    // MARK: Vectors

    /// Computes and stores the vector for one memory, best effort.
    ///
    /// Best effort throughout: no encoder, no cache, or an encoder that declines
    /// the text all leave the memory without a vector, and a memory without a
    /// vector ranks on words. Writing a memory must never fail because indexing
    /// it did.
    private func refreshEmbedding(for memory: MemoryItem) async {
        guard let encoder, let embeddings else { return }
        guard let vector = try? await encoder.embedding(for: memory.content), !vector.isEmpty
        else { return }
        try? await embeddings.store(
            MemoryEmbedding(
                memoryID: memory.id.rawValue,
                vector: vector,
                encoder: encoder.identity,
                contentHash: MemoryContentHash.hash(memory.content),
                createdAt: dateProvider.now
            ),
            for: memory.id
        )
    }

    /// Cached vectors for these memories, where they are still valid.
    private func vectors(for memories: [MemoryItem]) async -> [MemoryItem.ID: SemanticVector] {
        guard let embeddings, let encoder else { return [:] }
        guard let stored = try? await embeddings.embeddings(for: memories.map(\.id)) else {
            return [:]
        }
        var valid: [MemoryItem.ID: SemanticVector] = [:]
        for memory in memories {
            guard
                let cached = stored[memory.id],
                cached.isValid(
                    for: MemoryContentHash.hash(memory.content),
                    encoder: encoder.identity
                )
            else { continue }
            valid[memory.id] = cached.vector
        }
        return valid
    }

    /// `supports` edges out of an edited memory, weakened.
    ///
    /// Not deleted. The consolidated fact really was built partly from this
    /// memory, and erasing that would lose provenance the user can otherwise
    /// still read. What changes is how much it is worth: the wording it
    /// supported is not the wording that exists now.
    private func staleSupportEdges(for memory: MemoryItem) async -> [MemoryRelation] {
        guard let relations else { return [] }
        guard let edges = try? await relations.relations(for: memory.id) else { return [] }
        return edges
            .filter { $0.type == .supports && $0.source == memory.id }
            .map { edge in
                MemoryRelation(
                    source: edge.source,
                    target: edge.target,
                    type: .supports,
                    confidence: min(edge.confidence, 0.4),
                    createdAt: edge.createdAt
                )
            }
    }
}

public enum MemoryServiceError: Error, Hashable, Sendable {
    case emptyContent
    case notFound
}
