import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory

/// Chooses which memories a turn should see.
///
/// The layer `ContextAssembler` delegates to. Assembling context is
/// orchestration — profile, tasks, events, memories — and ranking is a
/// judgement about relevance; keeping them apart is what lets the ranking be
/// tuned and tested without touching the turn pipeline.
///
/// Everything here is local. No provider is asked which memories matter, so
/// retrieval behaves identically with the remote model, the Apple model, a
/// local model, the scripted stand-in and in tests — and works with no network
/// and no credential.
public struct MemoryRetrievalService: Sendable {
    private let repository: any MemoryRepository
    private let ranker: MemoryRanker
    private let policy: MemoryRelevancePolicy

    public init(
        repository: any MemoryRepository,
        policy: MemoryRelevancePolicy = .default,
        matcher: any MemorySemanticMatcher = LexicalSemanticMatcher()
    ) {
        self.repository = repository
        self.policy = policy
        self.ranker = MemoryRanker(policy: policy, matcher: matcher)
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
        // Candidates come from the repository unfiltered. Narrowing by category
        // before scoring would be faster and wrong: a "when should I leave"
        // question is answered by a `place` memory that shares no cue word with
        // it, and pre-filtering is how that memory disappears.
        //
        // For the sizes this app deals in — hundreds of memories, low thousands
        // at worst — scoring them all is microseconds, and it happens once per
        // turn. If that ever stops being true, the fix is a cheap prefilter on
        // term overlap, not a different architecture.
        let candidates = try await repository.all()
        guard !candidates.isEmpty else { return [] }

        return ranker.select(
            from: candidates,
            query: MemoryQuery(
                text: query,
                limit: limit ?? policy.maximumMemories,
                now: now
            )
        )
    }
}
