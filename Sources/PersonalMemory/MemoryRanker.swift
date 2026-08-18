import AssistantDomain
import Foundation

/// Why a memory scored what it did.
///
/// Kept because tuning retrieval blind is guesswork: when the camera preference
/// turns up in a scheduling question, this says whether relevance was too
/// generous or the category weighting too weak. Available to tests and to
/// development tooling. **Never shown to the user and never sent to a model** —
/// see `Docs/MEMORY.md` on privacy.
public struct MemoryScoreBreakdown: Hashable, Sendable {
    public var memory: MemoryItem
    public var relevance: Double
    public var salience: Double
    public var recency: Double
    public var confidence: Double
    public var categoryAffinity: Double
    public var finalScore: Double

    public init(
        memory: MemoryItem,
        relevance: Double,
        salience: Double,
        recency: Double,
        confidence: Double,
        categoryAffinity: Double,
        finalScore: Double
    ) {
        self.memory = memory
        self.relevance = relevance
        self.salience = salience
        self.recency = recency
        self.confidence = confidence
        self.categoryAffinity = categoryAffinity
        self.finalScore = finalScore
    }
}

/// Scores memories against a request.
///
/// Pure, synchronous and offline. **No model is consulted.** Asking an LLM
/// which memories are relevant would mean sending it every memory the user has
/// — the opposite of the privacy and prompt-size goals — and would make recall
/// depend on the network, on a credential, and on which provider happened to be
/// selected. Retrieval belongs to the application.
public struct MemoryRanker: Sendable {
    private let policy: MemoryRelevancePolicy
    private let matcher: any MemorySemanticMatcher
    /// Used at selection time only, to keep contradictions out of one prompt.
    private let deduplicator: MemoryDeduplicator

    public init(
        policy: MemoryRelevancePolicy = .default,
        matcher: any MemorySemanticMatcher = LexicalSemanticMatcher(),
        deduplicator: MemoryDeduplicator = MemoryDeduplicator()
    ) {
        self.policy = policy
        self.matcher = matcher
        self.deduplicator = deduplicator
    }

    /// Scores every candidate, best first.
    ///
    /// Returns breakdowns rather than bare memories so the caller can apply a
    /// threshold and a budget without scoring twice.
    public func score(
        _ candidates: [MemoryItem],
        query: MemoryQuery
    ) -> [MemoryScoreBreakdown] {
        let filtered = candidates.filter { candidate in
            // Cheap eliminations first: an empty memory says nothing, and an
            // explicit category or tag filter is the caller being specific.
            guard !candidate.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            if !query.kinds.isEmpty, !query.kinds.contains(candidate.kind) { return false }
            if !query.tags.isEmpty {
                let wanted = Set(query.tags.map { $0.lowercased() })
                guard !wanted.isDisjoint(with: Set(candidate.tags.map { $0.lowercased() }))
                else { return false }
            }
            return true
        }

        let queryText = query.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let queryProfile = MemoryTextProfile(queryText)
        let intent = MemoryQueryIntent.detect(in: queryProfile)

        let scored = filtered.map { memory -> MemoryScoreBreakdown in
            // With no query text there is nothing to be relevant *to*, so
            // relevance is neutral and the standing signals decide. That is the
            // "show me what you know" case, not the "answer this" case.
            let relevance = queryProfile.isEmpty
                ? 0.5
                : matcher.similarity(query: queryProfile, memory: profile(for: memory))

            let recency = query.now.map {
                policy.recency(of: max(memory.updatedAt, memory.createdAt), now: $0)
            } ?? 1.0

            let affinity = intent.affinity(for: memory.kind)

            let total =
                policy.relevanceWeight * relevance
                + policy.salienceWeight * memory.salience
                + policy.recencyWeight * recency
                + policy.confidenceWeight * memory.confidence
                + policy.categoryWeight * affinity

            let denominator =
                policy.relevanceWeight + policy.salienceWeight + policy.recencyWeight
                + policy.confidenceWeight + policy.categoryWeight

            return MemoryScoreBreakdown(
                memory: memory,
                relevance: relevance,
                salience: memory.salience,
                recency: recency,
                confidence: memory.confidence,
                categoryAffinity: affinity,
                finalScore: denominator > 0 ? total / denominator : 0
            )
        }

        return scored.sorted { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            // Fully determined order. Two identical scores must not come back
            // in a different order on a different run.
            if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
            return lhs.memory.id.rawValue.uuidString < rhs.memory.id.rawValue.uuidString
        }
    }

    /// Scores, then applies the threshold, the count limit and the budget.
    ///
    /// The whole selection in one place, because "top five" and "only if
    /// relevant" have to be applied together — taking five and then filtering,
    /// or filtering and then taking five, give different answers and only one
    /// of them is right.
    public func select(
        from candidates: [MemoryItem],
        query: MemoryQuery
    ) -> [MemoryScoreBreakdown] {
        let limit = min(policy.maximumMemories, max(0, query.limit))
        var budget = policy.characterBudget
        var selected: [MemoryScoreBreakdown] = []

        for candidate in score(candidates, query: query) {
            guard selected.count < limit else { break }

            // Relevance first, and on its own. The weighted score alone would
            // not keep an unrelated memory out: salience, confidence and
            // category affinity are collected regardless of the request, and a
            // salient, certain, well-categorised memory clears any sensible
            // score threshold while having nothing to do with what was asked.
            // A `continue` rather than a `break` because the ordering is by
            // final score, so a zero-relevance memory can outrank a weakly
            // relevant one and must not take it down with it.
            guard candidate.relevance >= policy.minimumRelevance else { continue }

            // Then strength. Never pad to the limit — injecting a marginal
            // memory costs context and invites the model to use it.
            guard candidate.finalScore >= policy.minimumScore else { break }

            // Never hand a model two memories that contradict each other. The
            // write path keeps a disagreement it could not settle — a guess
            // that clashes with something the user said stays visible in the
            // Memory screen rather than being silently overwritten — but a
            // prompt containing both is just an invitation to pick one at
            // random, and the whole point of ranking locally is that the
            // application decides.
            //
            // The higher-scoring one wins because it is already first: newer,
            // more confident and more explicitly sourced memories score higher,
            // so the order encodes the preference and there is no second rule
            // to keep consistent with the first.
            //
            // Only outright contradictions are dropped. Two memories that merely
            // say similar things are both allowed through — spotting redundancy
            // is the write path's job, and being aggressive here would silently
            // thin out a prompt on a judgement the user never sees.
            let contradictsSelection = deduplicator.classify(
                candidate.memory,
                against: selected.map(\.memory)
            )
            if case .conflicting = contradictsSelection { continue }

            let cost = candidate.memory.content.count
            guard cost <= budget else {
                // One very long memory must not eat the whole allowance, but
                // nor should it block the shorter ones behind it.
                continue
            }
            budget -= cost
            selected.append(candidate)
        }

        return selected
    }

    /// Ranking as the repository protocol asks for it: memories only.
    public func rank(_ candidates: [MemoryItem], query: MemoryQuery) -> [MemoryItem] {
        score(candidates, query: query)
            .prefix(max(0, query.limit))
            .map(\.memory)
    }

    private func profile(for memory: MemoryItem) -> MemoryTextProfile {
        // Tags are part of what a memory is about, so they participate in
        // matching rather than only in filtering.
        MemoryTextProfile(([memory.content] + memory.tags).joined(separator: " "))
    }
}
