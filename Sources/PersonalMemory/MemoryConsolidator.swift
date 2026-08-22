import AssistantDomain
import Foundation

/// One consolidation: the fact that survives, and everything it was built from.
public struct MemoryConsolidation: Hashable, Sendable {
    /// The surviving fact. Its id is derived from the sources, so re-running
    /// consolidation on the same cluster produces the same record.
    public var consolidated: MemoryItem
    /// The memories it replaces, updated to `superseded`.
    public var superseded: [MemoryItem]
    /// `supports` and `derivedFrom` edges tying the two together.
    public var relations: [MemoryRelation]

    public init(
        consolidated: MemoryItem,
        superseded: [MemoryItem],
        relations: [MemoryRelation]
    ) {
        self.consolidated = consolidated
        self.superseded = superseded
        self.relations = relations
    }
}

/// Turns several statements of the same fact into one.
///
/// ## The example this exists for
///
/// > I take about 30 minutes to get to work.
/// > My commute is usually half an hour.
/// > It normally takes around 30 minutes to drive to work.
///
/// Three rows in the Memory screen, three entries competing for the same slot in
/// every prompt, one fact. After consolidation there is one active memory and
/// three superseded ones linked to it, still visible, still restorable by
/// deleting the consolidated fact.
///
/// ## Conservative, and why that is the whole design
///
/// Merging is destructive in a way that keeping is not. A redundant memory costs
/// a little context; a wrongly merged pair loses a distinction the user made and
/// cannot easily get back. So every one of these stays separate, and each has
/// its own guard rather than relying on a threshold to catch it:
///
/// - "Commute takes 30 minutes" / "Commute takes 45 minutes during rush hour" —
///   different conditions.
/// - "Normal commute is 30 minutes" / "Rush-hour commute is 45 minutes" —
///   different numbers, which is the entire content of the distinction.
/// - "I like coffee" / "I don't like coffee after 6pm" — different polarity and
///   different conditions.
/// - Anything about work and anything about the gym — different subjects.
///
/// ## No model
///
/// The surviving wording is *chosen* from the sources, never generated. That is
/// deliberate beyond avoiding a network call: a generated summary is a sentence
/// the user never said, presented in their memory store as something they did.
/// Picking the clearest statement they actually made keeps the store truthful
/// and keeps consolidation deterministic enough to test.
public struct MemoryConsolidator: Sendable {
    /// How many statements make a cluster worth collapsing.
    ///
    /// Two. The write path already folds obvious duplicates as they arrive, so
    /// what reaches here is what the deduplicator could not see at the time —
    /// usually because the vector for one of them did not exist yet.
    public var minimumClusterSize: Int

    /// The most sources one consolidated fact may absorb in a single pass.
    ///
    /// A bound on work, not a judgement: maintenance runs opportunistically and
    /// must not turn into an unbounded scan when somebody has said the same
    /// thing thirty times.
    public var maximumClusterSize: Int

    /// How much repeated agreement may add to confidence, per extra statement.
    public var agreementBonus: Double

    /// The most repetition alone can add.
    ///
    /// Section 36. Hearing a guess three times is not the same as being told
    /// once, and a system where repetition converges on certainty is a system
    /// that talks itself into things.
    public var maximumAgreementBonus: Double

    /// The ceiling on a consolidation with no explicit statement behind it.
    ///
    /// Below `MemorySource.user.defaultConfidence`, so no pile of inferences can
    /// ever reach the standing of one sentence the user said.
    public var inferredConfidenceCeiling: Double

    private let policy: MemoryRelevancePolicy
    private let matcher: any MemorySemanticMatcher

    public init(
        minimumClusterSize: Int = 2,
        maximumClusterSize: Int = 8,
        agreementBonus: Double = 0.04,
        maximumAgreementBonus: Double = 0.12,
        inferredConfidenceCeiling: Double = 0.85,
        policy: MemoryRelevancePolicy = .default,
        matcher: any MemorySemanticMatcher = LexicalSemanticMatcher()
    ) {
        self.minimumClusterSize = minimumClusterSize
        self.maximumClusterSize = maximumClusterSize
        self.agreementBonus = agreementBonus
        self.maximumAgreementBonus = maximumAgreementBonus
        self.inferredConfidenceCeiling = inferredConfidenceCeiling
        self.policy = policy
        self.matcher = matcher
    }

    /// Every consolidation worth making over this set of memories.
    ///
    /// ## Idempotent by construction, not by checking
    ///
    /// Section 100's pathological loop — A+B→C, then C+A→D, then D+B→E — cannot
    /// be expressed here, and not because a guard rejects it. Consolidated
    /// memories are excluded from clustering (`isConsolidated`), and their
    /// sources leave the pool the moment they become `superseded`. After one
    /// pass there is nothing left for a second pass to see. Running maintenance
    /// twice is a no-op the second time, which is a stronger property than
    /// "produces the same answer twice".
    ///
    /// A fourth statement of the same fact arriving later does not restart the
    /// loop either: the write path finds it a near-duplicate of the *active*
    /// consolidated memory and folds it in, which is where that belongs.
    public func consolidations(
        among memories: [MemoryItem],
        vectors: [MemoryItem.ID: SemanticVector] = [:],
        now: Date
    ) -> [MemoryConsolidation] {
        let candidates = memories.filter(isEligible).sorted { lhs, rhs in
            // Oldest first, so a cluster's identity does not depend on the order
            // the repository happened to return.
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
        }
        guard candidates.count >= minimumClusterSize else { return [] }

        var used: Set<MemoryItem.ID> = []
        var results: [MemoryConsolidation] = []

        for seed in candidates where !used.contains(seed.id) {
            var cluster = [seed]
            for other in candidates
            where other.id != seed.id && !used.contains(other.id)
                && cluster.count < maximumClusterSize {
                guard cluster.allSatisfy({ isSameFact($0, other, vectors: vectors) }) else {
                    continue
                }
                cluster.append(other)
            }

            guard cluster.count >= minimumClusterSize else { continue }
            for member in cluster { used.insert(member.id) }
            results.append(consolidate(cluster, now: now))
        }

        return results
    }

    // MARK: Eligibility

    private func isEligible(_ memory: MemoryItem) -> Bool {
        guard memory.lifecycle == .active else { return false }
        // Section 99: a memory the user edited is theirs. Rewriting it from the
        // sources it once summarised would be the app overruling them on the
        // next maintenance pass.
        guard !memory.isProtected else { return false }
        // Section 100: a consolidated fact is never an input to another
        // consolidation.
        guard !memory.isConsolidated else { return false }
        return !memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether two memories are close enough to be one fact.
    ///
    /// Every guard here is a `false` that a similarity score would have got
    /// wrong. They run before the score, not after it.
    private func isSameFact(
        _ lhs: MemoryItem,
        _ rhs: MemoryItem,
        vectors: [MemoryItem.ID: SemanticVector]
    ) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        guard MemoryEntityExtractor.shareEntity(lhs.entityKeys, rhs.entityKeys) else {
            return false
        }

        let left = MemoryTextProfile(lhs.content)
        let right = MemoryTextProfile(rhs.content)
        guard !left.isEmpty, !right.isEmpty else { return false }

        // Polarity. "I like coffee" and "I don't like coffee" are a hair apart
        // in vector space and opposite in meaning.
        guard !left.disagreesInPolarity(with: right) else { return false }

        // Conditions. "During rush hour" makes a different claim about a
        // different situation — section 32, and the reason both statements are
        // true at once.
        guard left.qualifiers == right.qualifiers else { return false }

        // Numbers. Where a memory names a quantity, the quantity usually *is*
        // the fact, and two different ones are two facts however alike the
        // surrounding words are.
        if !left.durations.isEmpty || !right.durations.isEmpty {
            guard !left.durations.isDisjoint(with: right.durations) else { return false }
        }

        let lexical = matcher.similarity(query: left, memory: right)
        let semantic: Double = {
            guard let a = vectors[lhs.id], let b = vectors[rhs.id] else { return 0 }
            return a.normalizedSimilarity(to: b)
        }()

        // Same quantity, same subject, same category, same conditions, same
        // polarity — plus one of the two similarity channels agreeing that this
        // is one statement said twice.
        let quantified = !left.durations.isEmpty && !right.durations.isEmpty
        return lexical >= policy.semanticDuplicateThreshold * 0.7
            || semantic >= policy.semanticDuplicateThreshold
            || (quantified && !left.terms.isDisjoint(with: right.terms))
    }

    // MARK: Building the surviving fact

    private func consolidate(_ cluster: [MemoryItem], now: Date) -> MemoryConsolidation {
        let sourceIDs = cluster.map(\.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let representative = bestWording(in: cluster)

        var consolidated = MemoryItem(
            // Derived from the exact set of sources, so the same cluster always
            // produces the same record rather than a new one each pass.
            id: MemoryItem.ID.deterministic(
                namespace: "memory-consolidation",
                name: sourceIDs.map(\.rawValue.uuidString).joined(separator: "+")
            ),
            kind: representative.kind,
            content: representative.content,
            salience: cluster.map(\.salience).max() ?? representative.salience,
            tags: Array(Set(cluster.flatMap(\.tags))).sorted(),
            createdAt: cluster.map(\.createdAt).min() ?? now,
            updatedAt: now,
            lastUsedAt: cluster.compactMap(\.lastUsedAt).max(),
            source: bestSource(in: cluster),
            confidence: confidence(for: cluster),
            lifecycle: .active,
            entityKeys: Array(Set(cluster.flatMap(\.entityKeys))).sorted(),
            consolidatedFrom: sourceIDs
        )
        // The consolidated fact inherits the earliest creation date so recency
        // ranking does not treat a summary of two-year-old statements as news,
        // but its own `updatedAt` is now, because the record really did change.
        consolidated.updatedAt = now

        let superseded = cluster.map { source -> MemoryItem in
            var updated = source
            updated.lifecycle = .superseded
            updated.updatedAt = now
            return updated
        }

        var relations: [MemoryRelation] = []
        for source in cluster {
            relations.append(
                MemoryRelation(
                    source: source.id,
                    target: consolidated.id,
                    type: .supports,
                    confidence: source.confidence,
                    createdAt: now
                )
            )
            relations.append(
                MemoryRelation(
                    source: consolidated.id,
                    target: source.id,
                    type: .derivedFrom,
                    confidence: 1.0,
                    createdAt: now
                )
            )
        }

        return MemoryConsolidation(
            consolidated: consolidated,
            superseded: superseded,
            relations: relations
        )
    }

    /// Which of the user's own sentences survives.
    ///
    /// Never a generated one. Preference order: something they stated, then the
    /// most confident, then the shortest — because among equally good statements
    /// of one fact, the shortest is usually the clearest, and it is also the
    /// cheapest to carry in every prompt from now on.
    private func bestWording(in cluster: [MemoryItem]) -> MemoryItem {
        cluster.min { lhs, rhs in
            if lhs.source.isExplicit != rhs.source.isExplicit { return lhs.source.isExplicit }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.content.count != rhs.content.count { return lhs.content.count < rhs.content.count }
            return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
        } ?? cluster[0]
    }

    private func bestSource(in cluster: [MemoryItem]) -> MemorySource {
        if cluster.contains(where: { $0.source == .manual }) { return .manual }
        if cluster.contains(where: { $0.source == .user }) { return .user }
        if cluster.contains(where: { $0.source == .observation }) { return .observation }
        if cluster.contains(where: { $0.source == .legacy }) { return .legacy }
        return .assistant
    }

    /// Agreement raises confidence, within limits.
    ///
    /// Section 36, as arithmetic. Each extra statement adds a little; the total
    /// bonus is capped; and a cluster with no explicit statement in it cannot
    /// climb past `inferredConfidenceCeiling` however many times the app
    /// convinced itself of the same thing.
    private func confidence(for cluster: [MemoryItem]) -> Double {
        let base = cluster.map(\.confidence).max() ?? 0.5
        let bonus = min(maximumAgreementBonus, agreementBonus * Double(cluster.count - 1))
        let raised = base + bonus
        guard cluster.contains(where: { $0.source.isExplicit }) else {
            return min(inferredConfidenceCeiling, raised)
        }
        return min(1, raised)
    }
}
