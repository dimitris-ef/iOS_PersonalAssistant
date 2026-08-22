import AssistantDomain
import Foundation

/// What a proposed memory turns out to be, relative to what is already stored.
public enum MemoryDuplication: Hashable, Sendable {
    /// Nothing like it. Store it.
    case distinct
    /// The same sentence, normalised. Refresh the existing record.
    case exactDuplicate(existing: MemoryItem)
    /// The same fact in different words.
    case nearDuplicate(existing: MemoryItem, similarity: Double)
    /// The same subject, a different answer. Someone's commute changed, or one
    /// of the two is wrong.
    case conflicting(existing: MemoryItem, similarity: Double)

    public var existing: MemoryItem? {
        switch self {
        case .distinct: return nil
        case .exactDuplicate(let item): return item
        case .nearDuplicate(let item, _), .conflicting(let item, _): return item
        }
    }
}

/// Decides whether a new memory is really new.
///
/// The bias is conservative, and deliberately so. Storing a redundant memory
/// wastes a little context; merging away a real distinction loses something the
/// user told the assistant and cannot easily get back. "Commute takes 30
/// minutes" and "commute takes 45 minutes during rush hour" are both true, and
/// a deduplicator eager enough to collapse them is worse than none.
///
/// Four guards, in order, and the order is the design:
///
/// 1. **Polarity.** "I like coffee" and "I don't like coffee" are one small word
///    apart and mean opposite things. No embedding can see that — negation is a
///    function word, and a vector model puts the two sentences almost on top of
///    each other. So polarity is checked *first*, before any similarity is
///    consulted, and a disagreement here can only ever become a conflict.
/// 2. **Qualifiers.** If one statement is conditional — during rush hour, at
///    weekends — and the other is not, they describe different situations and
///    are left alone whatever their word overlap.
/// 3. **Quantities.** Same subject, different duration, means the facts
///    disagree. That is a conflict to resolve, never a duplicate to discard.
/// 4. **Similarity.** Only then does strong overlap — lexical *or* semantic —
///    mean "the same thing said twice".
///
/// ## Why semantic similarity is added here rather than substituted
///
/// Because meaning is the one thing lexical matching could not do and the one
/// thing vectors cannot be trusted alone to do. "It takes me 30 minutes to drive
/// to work" and "my commute is roughly half an hour" share a single content
/// word; only a vector sees they are one statement. And "I like coffee" and "I
/// don't" share every content word; only the guards above see they are two. Each
/// covers the other's blind spot, which is why both are here and why neither
/// gets a veto over the guards.
public struct MemoryDeduplicator: Sendable {
    /// How alike two memories must be before they are considered the same fact.
    ///
    /// High on purpose. Lowering it merges more aggressively, which is the
    /// direction that loses data.
    public var nearDuplicateThreshold: Double

    /// How alike two memories must be before a differing quantity counts as a
    /// disagreement rather than two unrelated facts.
    ///
    /// Lower than the duplicate threshold, because a conflict is not resolved
    /// destructively — the worst case is keeping both and letting the user
    /// decide, which is where an uncertain call should land.
    public var conflictThreshold: Double

    /// How alike two memories must *mean* before that counts as saying the same
    /// thing. Only ever consulted after the polarity, qualifier and quantity
    /// guards have passed.
    public var semanticDuplicateThreshold: Double

    /// The meaning overlap at which a differing number becomes a disagreement
    /// about one subject rather than two unrelated facts.
    public var semanticConflictThreshold: Double

    private let matcher: any MemorySemanticMatcher

    public init(
        nearDuplicateThreshold: Double = 0.62,
        conflictThreshold: Double = 0.45,
        semanticDuplicateThreshold: Double = 0.9,
        semanticConflictThreshold: Double = 0.75,
        matcher: any MemorySemanticMatcher = LexicalSemanticMatcher()
    ) {
        self.nearDuplicateThreshold = nearDuplicateThreshold
        self.conflictThreshold = conflictThreshold
        self.semanticDuplicateThreshold = semanticDuplicateThreshold
        self.semanticConflictThreshold = semanticConflictThreshold
        self.matcher = matcher
    }

    /// The same thresholds, taken from a retrieval policy.
    ///
    /// So that the numbers live in one place. A duplicate threshold tuned here
    /// and a semantic threshold tuned in the policy would drift apart, and the
    /// symptom — memories merging in one code path and not another — is
    /// miserable to diagnose.
    public init(policy: MemoryRelevancePolicy, matcher: any MemorySemanticMatcher = LexicalSemanticMatcher()) {
        self.init(
            semanticDuplicateThreshold: policy.semanticDuplicateThreshold,
            semanticConflictThreshold: policy.semanticConflictThreshold,
            matcher: matcher
        )
    }

    /// Classifies `candidate` against everything already stored.
    ///
    /// `vectors` is optional throughout. When it is empty — no encoder on this
    /// device, or a memory whose vector has not been generated yet — every
    /// decision falls back to the lexical path, which is the behaviour this had
    /// before Part 9 and is still correct, merely blinder.
    public func classify(
        _ candidate: MemoryItem,
        against existing: [MemoryItem],
        vectors: [MemoryItem.ID: SemanticVector] = [:]
    ) -> MemoryDuplication {
        let candidateProfile = MemoryTextProfile(candidate.content)
        guard !candidateProfile.isEmpty else { return .distinct }

        var best: MemoryDuplication = .distinct
        var bestSimilarity = 0.0

        for stored in existing where stored.id != candidate.id {
            let storedProfile = MemoryTextProfile(stored.content)

            // Word for word, once normalised. The same sentence is the same
            // sentence whatever category it was filed under.
            if storedProfile.normalized == candidateProfile.normalized {
                return .exactDuplicate(existing: stored)
            }

            // Different categories are usually different facts. Comparing a
            // place to a preference invites nonsense matches.
            guard stored.kind == candidate.kind else { continue }

            let lexicalSimilarity = matcher.similarity(
                query: candidateProfile,
                memory: storedProfile
            )
            let semanticSimilarity: Double = {
                guard
                    let candidateVector = vectors[candidate.id],
                    let storedVector = vectors[stored.id]
                else { return 0 }
                return candidateVector.normalizedSimilarity(to: storedVector)
            }()
            let sharedSubject = !storedProfile.terms.isDisjoint(with: candidateProfile.terms)
            let sameEntities = MemoryEntityExtractor.shareEntity(
                candidate.entityKeys,
                stored.entityKeys
            )

            // Guard 1: polarity. Before similarity of any kind is looked at,
            // because this is precisely where similarity lies. Two statements
            // about the same subject that point opposite ways are a conflict —
            // never a duplicate, and never merged.
            if candidateProfile.disagreesInPolarity(with: storedProfile) {
                let related = sharedSubject
                    && sameEntities
                    && (lexicalSimilarity >= conflictThreshold
                        || semanticSimilarity >= semanticConflictThreshold)
                if related, lexicalSimilarity > bestSimilarity {
                    best = .conflicting(existing: stored, similarity: lexicalSimilarity)
                    bestSimilarity = lexicalSimilarity
                }
                continue
            }

            // Guard 2: a condition on one side and not the other. "During rush
            // hour" describes a different situation, whatever the word overlap.
            guard storedProfile.qualifiers == candidateProfile.qualifiers else { continue }

            // Guard 2b: different subjects, when both memories name one. Stops
            // "the commute to work" being compared with "the walk to the gym"
            // on the strength of both being journeys.
            guard sameEntities else { continue }

            let similarity = max(lexicalSimilarity, semanticSimilarity)
            let bothQuantified =
                !storedProfile.durations.isEmpty && !candidateProfile.durations.isEmpty
            let quantitiesAgree =
                bothQuantified && !storedProfile.durations.isDisjoint(with: candidateProfile.durations)
            let quantitiesDisagree =
                bothQuantified && storedProfile.durations.isDisjoint(with: candidateProfile.durations)

            // Guard 3: the same subject with a different number is a
            // disagreement, not a repetition. Someone's commute changed, or one
            // of the two is wrong — either way, discarding one silently is the
            // wrong answer.
            //
            // This is also the guard that most needs to survive semantic
            // matching. "Normal commute is 30 minutes" and "rush-hour commute is
            // 45 minutes" are, in vector terms, nearly identical sentences —
            // the number is the entire distinction, and it is the part a bag of
            // concepts throws away first. Quantities are compared as numbers,
            // before similarity is allowed to conclude anything.
            if quantitiesDisagree,
               sharedSubject || semanticSimilarity >= semanticConflictThreshold,
               similarity >= conflictThreshold || semanticSimilarity >= semanticConflictThreshold {
                if similarity > bestSimilarity {
                    best = .conflicting(existing: stored, similarity: similarity)
                    bestSimilarity = similarity
                }
                continue
            }

            // Three ways to be the same fact, having survived every guard.
            //
            // Strong word overlap; strong meaning overlap; or the older
            // stand-in for meaning — same category, same subject, same quantity
            // — which is what caught "it takes me 30 minutes to drive to work"
            // and "my commute is roughly half an hour" before there were
            // vectors. The stand-in stays: it costs nothing, it works when no
            // encoder is available, and it is stricter than the semantic path
            // rather than looser, so it can only agree.
            let isSameFact = similarity >= nearDuplicateThreshold
                || semanticSimilarity >= semanticDuplicateThreshold
                || (quantitiesAgree && sharedSubject)
            guard isSameFact else { continue }

            if similarity >= bestSimilarity {
                best = .nearDuplicate(existing: stored, similarity: similarity)
                bestSimilarity = similarity
            }
        }

        return best
    }

    /// Folds a duplicate into the record that already exists.
    ///
    /// The identifier never changes — anything referring to this memory keeps
    /// referring to it, and the user's Memory screen does not sprout a second
    /// row saying the same thing.
    ///
    /// Confidence only ever rises here, and only when the new statement comes
    /// from a more trustworthy source: hearing the same thing twice is
    /// corroboration. It is not licence for an inference to overwrite what
    /// someone actually said.
    public func merged(
        _ existing: MemoryItem,
        with candidate: MemoryItem,
        at date: Date
    ) -> MemoryItem {
        var merged = existing
        merged.updatedAt = date
        merged.salience = max(existing.salience, candidate.salience)
        merged.tags = Array(Set(existing.tags).union(candidate.tags)).sorted()

        if candidate.source.isExplicit && !existing.source.isExplicit {
            // The user has now said in words what the assistant had guessed.
            merged.content = candidate.content
            merged.source = candidate.source
            merged.confidence = max(existing.confidence, candidate.confidence)
        } else {
            merged.confidence = max(existing.confidence, candidate.confidence)
        }

        return merged
    }

    /// Resolves two memories that disagree.
    ///
    /// Not a truth-maintenance system, and not trying to be. One rule, applied
    /// to the only evidence available: a newer explicit statement replaces an
    /// older one, because people's circumstances change and they are the
    /// authority on their own. Anything weaker than that is kept alongside,
    /// where the user can see both and delete the wrong one.
    public func resolution(
        existing: MemoryItem,
        candidate: MemoryItem
    ) -> MemoryConflictResolution {
        let candidateIsBetterEvidence =
            (candidate.source.isExplicit && !existing.source.isExplicit)
            || (candidate.source.isExplicit == existing.source.isExplicit
                && candidate.confidence >= existing.confidence)

        guard candidateIsBetterEvidence else { return .keepBoth }
        return .replaceContent
    }
}

/// What to do about two memories that disagree.
public enum MemoryConflictResolution: Hashable, Sendable {
    /// Update the stored record in place, keeping its identifier and history.
    case replaceContent
    /// Store both. The user can see the disagreement and settle it.
    case keepBoth
}
