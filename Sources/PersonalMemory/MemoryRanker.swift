import AssistantDomain
import Foundation

/// Why a memory scored what it did.
///
/// Kept because tuning retrieval blind is guesswork: when the camera preference
/// turns up in a scheduling question, this says whether meaning was too
/// generous, the category weighting too weak, or a stale vector still in play.
/// Available to tests and to development tooling. **Never shown to the user and
/// never sent to a model** — see `Docs/MEMORY.md` on privacy.
public struct MemoryScoreBreakdown: Hashable, Sendable {
    public var memory: MemoryItem
    /// Shared words, phrases and durations.
    public var lexical: Double
    /// Cosine against the query vector. Zero when no vector was available,
    /// which is how the fallback shows up here rather than as a missing field.
    public var semantic: Double
    public var salience: Double
    public var recency: Double
    public var confidence: Double
    public var categoryAffinity: Double
    /// How much the way this was learned is worth.
    public var sourceTrust: Double
    /// A nudge from being linked to something that already scored well.
    public var relationBoost: Double
    /// Subtracted for disagreeing with a better-evidenced memory.
    public var conflictPenalty: Double
    public var finalScore: Double

    public init(
        memory: MemoryItem,
        lexical: Double,
        semantic: Double = 0,
        salience: Double,
        recency: Double,
        confidence: Double,
        categoryAffinity: Double,
        sourceTrust: Double = 0,
        relationBoost: Double = 0,
        conflictPenalty: Double = 0,
        finalScore: Double
    ) {
        self.memory = memory
        self.lexical = lexical
        self.semantic = semantic
        self.salience = salience
        self.recency = recency
        self.confidence = confidence
        self.categoryAffinity = categoryAffinity
        self.sourceTrust = sourceTrust
        self.relationBoost = relationBoost
        self.conflictPenalty = conflictPenalty
        self.finalScore = finalScore
    }

    /// The strongest evidence that this memory is about the request at all.
    ///
    /// Either channel is enough. Requiring both would discard the case semantic
    /// retrieval exists for — a memory that means the same thing in entirely
    /// different words — and requiring only meaning would discard the case a
    /// vector model is worst at, an exact quoted phrase it has never seen.
    public var topicality: Double { max(lexical, semantic) }
}

/// Everything ranking needs to know that is not on the memories themselves.
///
/// Gathered into one value so ``MemoryRanker`` can stay pure and synchronous.
/// Vectors are resolved before scoring, by the service that owns the encoder and
/// the cache; by the time a ranker sees them they are data, and scoring a few
/// hundred memories is a loop rather than an `await` inside one.
public struct MemoryRankingContext: Sendable {
    /// The query as a vector, when the encoder produced one.
    ///
    /// Nil is the fallback path and is entirely normal: no encoder on this
    /// device, the framework declined the language, or the text was too thin to
    /// encode. Ranking continues on lexical overlap.
    public var queryVector: SemanticVector?
    /// Vectors for the candidates, by memory id. Missing entries score zero on
    /// the semantic channel rather than being excluded.
    public var memoryVectors: [MemoryItem.ID: SemanticVector]
    /// One-hop links between candidates.
    public var relations: [MemoryRelation]
    /// The encoder's own view of where "about the same thing" begins.
    ///
    /// Nil uses the policy's floor alone. When both are present the higher wins,
    /// so an encoder can only ever be more conservative than the product policy
    /// — see ``SemanticEncoder/similarityFloor``.
    public var semanticFloor: Double?

    public init(
        queryVector: SemanticVector? = nil,
        memoryVectors: [MemoryItem.ID: SemanticVector] = [:],
        relations: [MemoryRelation] = [],
        semanticFloor: Double? = nil
    ) {
        self.queryVector = queryVector
        self.memoryVectors = memoryVectors
        self.relations = relations
        self.semanticFloor = semanticFloor
    }

    /// Nothing semantic available. The lexical path, named.
    public static let lexicalOnly = MemoryRankingContext()

    public var hasSemantics: Bool {
        guard let queryVector else { return false }
        return !queryVector.isEmpty && !memoryVectors.isEmpty
    }
}

/// Scores memories against a request.
///
/// Pure, synchronous and offline. **No model is consulted.** Asking an LLM which
/// memories are relevant would mean sending it every memory the user has — the
/// opposite of the privacy and prompt-size goals — and would make recall depend
/// on the network, on a credential, and on which provider happened to be
/// selected. Retrieval belongs to the application.
///
/// ## Hybrid, not replaced
///
/// Semantic similarity is added to the existing signals, not put in their place.
/// The reason is section 8's example and it is worth stating plainly: an
/// inference the app made about a twenty-minute commute and a sentence the user
/// typed saying thirty are, to a vector model, the same sentence. Cosine cannot
/// see who said it, when, or how sure anyone was. Those are exactly the
/// questions the other weights answer, and they are the difference between a
/// memory system and a search index.
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
        query: MemoryQuery,
        context: MemoryRankingContext = .lexicalOnly
    ) -> [MemoryScoreBreakdown] {
        let filtered = candidates.filter { candidate in
            // Cheap eliminations first: an empty memory says nothing, and an
            // explicit category, tag or lifecycle filter is the caller being
            // specific.
            guard !candidate.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            if !query.lifecycles.isEmpty, !query.lifecycles.contains(candidate.lifecycle) {
                return false
            }
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
        let effective = context.hasSemantics ? policy : policy.withoutSemantics

        // Pass one: everything that depends only on the memory and the query.
        var scored = filtered.map { memory in
            base(
                for: memory,
                queryProfile: queryProfile,
                intent: intent,
                query: query,
                context: context,
                policy: effective
            )
        }

        // Pass two: the relation boost, which needs pass one's answers. A
        // memory linked to something already scoring well gets a nudge — and
        // only a nudge, from the single best neighbour rather than the sum, so
        // a densely linked cluster cannot lift itself into the prompt.
        scored = applyRelationBoost(to: scored, context: context, policy: effective)

        return scored.sorted { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            // Fully determined order. Two identical scores must not come back
            // in a different order on a different run.
            if lhs.topicality != rhs.topicality { return lhs.topicality > rhs.topicality }
            return lhs.memory.id.rawValue.uuidString < rhs.memory.id.rawValue.uuidString
        }
    }

    // MARK: Scoring

    private func base(
        for memory: MemoryItem,
        queryProfile: MemoryTextProfile,
        intent: MemoryQueryIntent,
        query: MemoryQuery,
        context: MemoryRankingContext,
        policy: MemoryRelevancePolicy
    ) -> MemoryScoreBreakdown {
        // With no query text there is nothing to be relevant *to*, so relevance
        // is neutral and the standing signals decide. That is the "show me what
        // you know" case, not the "answer this" case.
        let lexical = queryProfile.isEmpty
            ? 0.5
            : matcher.similarity(query: queryProfile, memory: profile(for: memory))

        let semantic: Double = {
            guard
                policy.semanticWeight > 0,
                let queryVector = context.queryVector,
                let memoryVector = context.memoryVectors[memory.id]
            else { return 0 }
            return queryVector.normalizedSimilarity(to: memoryVector)
        }()

        let recency = query.now.map {
            policy.recency(of: max(memory.updatedAt, memory.createdAt), now: $0)
        } ?? 1.0

        let affinity = intent.affinity(for: memory.kind)
        let trust = policy.sourceTrust(of: memory.source)
        // Conflicting is the only lifecycle that can reach here and still be
        // wrong about the world: the state exists precisely because the app
        // could not settle a disagreement. It is penalised rather than filtered
        // so a caller that deliberately asks for it — the Memory screen — still
        // sees a sensible order.
        let penalty = memory.lifecycle == .conflicting ? policy.conflictPenalty : 0

        let total =
            policy.relevanceWeight * lexical
            + policy.semanticWeight * semantic
            + policy.salienceWeight * memory.salience
            + policy.recencyWeight * recency
            + policy.confidenceWeight * memory.confidence
            + policy.categoryWeight * affinity
            + policy.sourceTrustWeight * trust
            - penalty

        let denominator =
            policy.relevanceWeight + policy.semanticWeight + policy.salienceWeight
            + policy.recencyWeight + policy.confidenceWeight + policy.categoryWeight
            + policy.sourceTrustWeight

        return MemoryScoreBreakdown(
            memory: memory,
            lexical: lexical,
            semantic: semantic,
            salience: memory.salience,
            recency: recency,
            confidence: memory.confidence,
            categoryAffinity: affinity,
            sourceTrust: trust,
            conflictPenalty: penalty,
            finalScore: denominator > 0 ? max(0, total / denominator) : 0
        )
    }

    /// One hop, best neighbour only, capped.
    ///
    /// Section 60's rule made structural rather than remembered: because the
    /// boost is applied once, after scoring, and reads only the pre-boost scores
    /// of neighbours, it cannot propagate. B cannot be lifted by C's boost from
    /// D, because C's boost does not exist yet when B reads it. A retrieval
    /// explosion is not something this has to be careful about; it is something
    /// it cannot express.
    private func applyRelationBoost(
        to scored: [MemoryScoreBreakdown],
        context: MemoryRankingContext,
        policy: MemoryRelevancePolicy
    ) -> [MemoryScoreBreakdown] {
        guard policy.relationWeight > 0, !context.relations.isEmpty else { return scored }

        let baseScores = Dictionary(
            scored.map { ($0.memory.id, $0.finalScore) },
            uniquingKeysWith: { first, _ in first }
        )

        // Symmetric relations are walked both ways; directed ones are not,
        // because "this consolidated fact came from that one" does not mean the
        // superseded source deserves to ride along.
        var neighbours: [MemoryItem.ID: Set<MemoryItem.ID>] = [:]
        for relation in context.relations {
            // Contradiction is a link, but a link to something the app has
            // already decided against. Boosting on it would surface both sides
            // of a settled disagreement in one prompt.
            guard relation.type != .contradicts, relation.type != .derivedFrom else { continue }
            neighbours[relation.source, default: []].insert(relation.target)
            if relation.type.isSymmetric {
                neighbours[relation.target, default: []].insert(relation.source)
            }
        }

        return scored.map { entry in
            guard let linked = neighbours[entry.memory.id], !linked.isEmpty else { return entry }
            let best = linked.compactMap { baseScores[$0] }.max() ?? 0
            guard best > 0 else { return entry }

            var boosted = entry
            boosted.relationBoost = policy.relationWeight * best
            boosted.finalScore = entry.finalScore + boosted.relationBoost
            return boosted
        }
    }

    // MARK: Selection

    /// Scores, then applies the threshold, the count limit and the budget.
    ///
    /// The whole selection in one place, because "top five" and "only if
    /// relevant" have to be applied together — taking five and then filtering,
    /// or filtering and then taking five, give different answers and only one
    /// of them is right.
    public func select(
        from candidates: [MemoryItem],
        query: MemoryQuery,
        context: MemoryRankingContext = .lexicalOnly
    ) -> [MemoryScoreBreakdown] {
        let limit = min(policy.maximumMemories, max(0, query.limit))
        var budget = policy.characterBudget
        var selected: [MemoryScoreBreakdown] = []
        let semanticAvailable = context.hasSemantics
        // Whichever bar is higher. The policy owns the product's floor and the
        // encoder owns its vector space's; neither may loosen the other.
        let semanticFloor = max(
            policy.minimumSemanticSimilarity,
            context.semanticFloor ?? policy.minimumSemanticSimilarity
        )

        for candidate in score(candidates, query: query, context: context) {
            guard selected.count < limit else { break }

            // Topicality first, and on its own. The weighted score alone would
            // not keep an unrelated memory out: salience, confidence, source
            // trust and category affinity are collected regardless of the
            // request, and a salient, certain, well-sourced memory clears any
            // sensible score threshold while having nothing to do with what was
            // asked.
            //
            // Two ways to be on topic and either will do — shared words, or
            // shared meaning. That disjunction is the whole of Part 9's
            // retrieval promise: "how long should I allow for my commute?" has
            // almost no lexical overlap with "it takes me half an hour to drive
            // to work", and demanding both channels agree would reject exactly
            // the memory the milestone is about.
            //
            // A `continue` rather than a `break` because the ordering is by
            // final score, so an off-topic memory can outrank a weakly relevant
            // one and must not take it down with it.
            let onTopic = candidate.lexical >= policy.minimumRelevance
                || (semanticAvailable && candidate.semantic >= semanticFloor)
            guard onTopic else { continue }

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
    public func rank(
        _ candidates: [MemoryItem],
        query: MemoryQuery,
        context: MemoryRankingContext = .lexicalOnly
    ) -> [MemoryItem] {
        score(candidates, query: query, context: context)
            .prefix(max(0, query.limit))
            .map(\.memory)
    }

    private func profile(for memory: MemoryItem) -> MemoryTextProfile {
        // Tags are part of what a memory is about, so they participate in
        // matching rather than only in filtering.
        MemoryTextProfile(([memory.content] + memory.tags).joined(separator: " "))
    }
}
