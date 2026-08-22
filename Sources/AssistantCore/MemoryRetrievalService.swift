import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory

/// What one retrieval cost and found, for tuning and for logs.
///
/// Counts and durations only — never a memory's text. Section 109: a log line
/// that quotes what the assistant recalled is a log line containing the most
/// personal thing this app holds.
public struct MemoryRetrievalMetrics: Hashable, Sendable {
    public var candidateCount: Int
    public var selectedCount: Int
    /// Vectors found in the cache and still valid.
    public var embeddingHits: Int
    /// Candidates whose vector was missing or stale.
    public var embeddingMisses: Int
    /// False when the query could not be encoded and ranking fell back.
    public var usedSemantics: Bool
    public var duration: TimeInterval

    public init(
        candidateCount: Int = 0,
        selectedCount: Int = 0,
        embeddingHits: Int = 0,
        embeddingMisses: Int = 0,
        usedSemantics: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.candidateCount = candidateCount
        self.selectedCount = selectedCount
        self.embeddingHits = embeddingHits
        self.embeddingMisses = embeddingMisses
        self.usedSemantics = usedSemantics
        self.duration = duration
    }
}

/// Chooses which memories a turn should see.
///
/// The layer `ContextAssembler` delegates to. Assembling context is
/// orchestration — profile, tasks, events, memories — and ranking is a
/// judgement about relevance; keeping them apart is what lets the ranking be
/// tuned and tested without touching the turn pipeline.
///
/// ## Everything here is local
///
/// No provider is asked which memories matter, and no provider produces the
/// vectors either. Retrieval behaves identically with the remote model, the
/// Apple model, a local model, the scripted stand-in and in tests — and works
/// with no network and no credential. Using the selected conversational provider
/// as the embedding service would mean uploading the user's entire memory store
/// to index it, which is the one thing this design exists to prevent.
///
/// ## The shape of a retrieval
///
/// ```
/// candidates (active only)
///     ↓
/// cached vectors, validated against content hash + encoder identity
///     ↓
/// one query vector, computed once and cached for the turn
///     ↓
/// hybrid rank: meaning + words + salience + confidence + recency
///              + category + source trust + relation boost − conflict
///     ↓
/// threshold, count limit, character budget
/// ```
///
/// Every step degrades. No encoder, a stale cache, a query that will not
/// encode — each of those removes the semantic channel and leaves the rest
/// working, which is why memory never becomes unusable because encoding failed.
public struct MemoryRetrievalService: Sendable {
    private let repository: any MemoryRepository
    private let relations: (any MemoryRelationRepository)?
    private let embeddings: (any MemoryEmbeddingStore)?
    private let encoder: (any SemanticEncoder)?
    private let queryCache: QueryVectorCache
    private let ranker: MemoryRanker
    private let policy: MemoryRelevancePolicy

    public init(
        repository: any MemoryRepository,
        relations: (any MemoryRelationRepository)? = nil,
        embeddings: (any MemoryEmbeddingStore)? = nil,
        encoder: (any SemanticEncoder)? = nil,
        policy: MemoryRelevancePolicy = .default,
        matcher: any MemorySemanticMatcher = LexicalSemanticMatcher()
    ) {
        self.repository = repository
        self.relations = relations
        self.embeddings = embeddings
        self.encoder = encoder
        self.policy = policy
        self.queryCache = QueryVectorCache()
        self.ranker = MemoryRanker(
            policy: policy,
            matcher: matcher,
            deduplicator: MemoryDeduplicator(policy: policy, matcher: matcher)
        )
    }

    /// The memories worth sending, best first.
    ///
    /// Returns fewer than the limit — often none — when nothing is relevant.
    /// That is the point: a request about paying a bill should not carry the
    /// user's camera preference just because there was room for it.
    public func relevantMemories(
        for query: String,
        now: Date,
        limit: Int? = nil
    ) async throws -> [MemoryItem] {
        try await selection(for: query, now: now, limit: limit).map(\.memory)
    }

    /// The same selection, with the reasoning attached.
    ///
    /// For tests and development tuning. Callers in the turn pipeline use
    /// ``relevantMemories(for:now:limit:)`` — a score has no business travelling
    /// any further than this module.
    public func selection(
        for query: String,
        now: Date,
        limit: Int? = nil
    ) async throws -> [MemoryScoreBreakdown] {
        try await retrieve(query: query, now: now, limit: limit).selection
    }

    /// The selection plus what it cost.
    public func retrieve(
        query: String,
        now: Date,
        limit: Int? = nil
    ) async throws -> (selection: [MemoryScoreBreakdown], metrics: MemoryRetrievalMetrics) {
        let started = Date()

        // Candidates come from the repository unfiltered by topic. Narrowing by
        // category before scoring would be faster and wrong: a "when should I
        // leave" question is answered by a `place` memory that shares no cue
        // word with it, and pre-filtering is how that memory disappears.
        //
        // Lifecycle *is* filtered, because archived and superseded memories are
        // deliberately not eligible — that is the whole point of the states.
        //
        // For the sizes this app deals in — hundreds of memories, low thousands
        // at worst — scoring them all is microseconds, and it happens once per
        // turn. If that ever stops being true, the fix is an approximate index
        // behind this same call, not a different architecture.
        let candidates = try await repository.all().filter(\.isRetrievable)
        guard !candidates.isEmpty else {
            return ([], MemoryRetrievalMetrics(duration: Date().timeIntervalSince(started)))
        }

        let context = await rankingContext(for: query, candidates: candidates)
        let selection = ranker.select(
            from: candidates,
            query: MemoryQuery(
                text: query,
                limit: limit ?? policy.maximumMemories,
                now: now
            ),
            context: context.context
        )

        let metrics = MemoryRetrievalMetrics(
            candidateCount: candidates.count,
            selectedCount: selection.count,
            embeddingHits: context.hits,
            embeddingMisses: candidates.count - context.hits,
            usedSemantics: context.context.hasSemantics,
            duration: Date().timeIntervalSince(started)
        )
        return (selection, metrics)
    }

    // MARK: Vectors

    private func rankingContext(
        for query: String,
        candidates: [MemoryItem]
    ) async -> (context: MemoryRankingContext, hits: Int) {
        var memoryVectors: [MemoryItem.ID: SemanticVector] = [:]
        var cacheHits = 0

        if let embeddings, let encoder {
            let stored = (try? await embeddings.embeddings(for: candidates.map(\.id))) ?? [:]
            var missing: [MemoryItem] = []

            for candidate in candidates {
                let hash = MemoryContentHash.hash(candidate.content)
                // Both halves of validity, every time. A vector whose text has
                // changed describes something the user no longer believes; a
                // vector from another encoder is in a different space and its
                // similarity is noise wearing the costume of a number.
                if let cached = stored[candidate.id],
                   cached.isValid(for: hash, encoder: encoder.identity) {
                    memoryVectors[candidate.id] = cached.vector
                    cacheHits += 1
                } else {
                    missing.append(candidate)
                }
            }

            // Lazy generation, bounded — section 13. A memory whose vector was
            // never computed, or whose text the user has since edited, is
            // encoded here rather than by a startup pass that would have to
            // walk the whole store before the app could answer anything.
            //
            // The budget is the point. Retrieval runs inside a turn, so this
            // may cost a few encodings and never a thousand; the rest are
            // picked up by the next retrieval, or by maintenance. Until then
            // those memories simply rank on words, which is the same fallback
            // that covers a device with no encoder at all.
            for candidate in missing.prefix(Self.lazyEmbeddingBudget) {
                guard let vector = try? await encoder.embedding(for: candidate.content),
                      !vector.isEmpty
                else { continue }
                memoryVectors[candidate.id] = vector
                try? await embeddings.store(
                    MemoryEmbedding(
                        memoryID: candidate.id.rawValue,
                        vector: vector,
                        encoder: encoder.identity,
                        contentHash: MemoryContentHash.hash(candidate.content),
                        createdAt: Date()
                    ),
                    for: candidate.id
                )
            }
        }

        let queryVector = memoryVectors.isEmpty ? nil : await queryVector(for: query)

        let edges = await loadRelations(for: candidates)
        return (
            MemoryRankingContext(
                queryVector: queryVector,
                memoryVectors: memoryVectors,
                relations: edges,
                semanticFloor: encoder?.similarityFloor
            ),
            cacheHits
        )
    }

    /// How many missing vectors one retrieval may generate.
    ///
    /// Small enough that a turn is never held up encoding a memory store, large
    /// enough that a fresh install stops needing the fallback within a handful
    /// of questions.
    private static let lazyEmbeddingBudget = 12

    /// One vector per query text, cached for as long as the service lives.
    ///
    /// Section 64. A turn asks once, but the same question arrives repeatedly in
    /// a session — a retry, a follow-up round of the agent loop, the executive
    /// support layer asking about travel time — and encoding is the one part of
    /// retrieval that is not microseconds.
    private func queryVector(for query: String) async -> SemanticVector? {
        guard let encoder else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = MemoryContentHash.hash(trimmed)
        if let cached = await queryCache.value(for: key, encoder: encoder.identity) {
            return cached
        }
        guard let vector = try? await encoder.embedding(for: trimmed), !vector.isEmpty else {
            // The fallback path, and an entirely normal one. Ranking continues
            // on lexical overlap.
            return nil
        }
        await queryCache.store(vector, for: key, encoder: encoder.identity)
        return vector
    }

    private func loadRelations(for candidates: [MemoryItem]) async -> [MemoryRelation] {
        guard let relations, policy.relationWeight > 0 else { return [] }
        guard let all = try? await relations.all() else { return [] }
        // Only edges between two candidates. An edge to something archived or
        // superseded cannot boost anything, and carrying it into ranking would
        // just be work.
        let ids = Set(candidates.map(\.id))
        return all.filter { ids.contains($0.source) && ids.contains($0.target) }
    }
}

/// Query vectors, kept for the life of the service.
///
/// Bounded, because a long session asks a lot of different questions and this is
/// a convenience rather than a store. Keyed by encoder identity as well as by
/// text so a composition that swapped encoders mid-flight cannot serve a vector
/// from the wrong space.
private actor QueryVectorCache {
    private var entries: [String: (identity: SemanticEncoderIdentity, vector: SemanticVector)] = [:]
    private var order: [String] = []
    private let limit = 32

    func value(for key: String, encoder: SemanticEncoderIdentity) -> SemanticVector? {
        guard let entry = entries[key], entry.identity == encoder else { return nil }
        return entry.vector
    }

    func store(_ vector: SemanticVector, for key: String, encoder: SemanticEncoderIdentity) {
        if entries[key] == nil {
            order.append(key)
            if order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        entries[key] = (encoder, vector)
    }
}
