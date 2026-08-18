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
/// Three guards, in order:
///
/// 1. **Qualifiers.** If one statement is conditional — during rush hour, at
///    weekends — and the other is not, they describe different situations and
///    are left alone whatever their word overlap.
/// 2. **Quantities.** Same subject, different duration, means the facts
///    disagree. That is a conflict to resolve, never a duplicate to discard.
/// 3. **Similarity.** Only then does strong overlap mean "the same thing said
///    twice".
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

    private let matcher: any MemorySemanticMatcher

    public init(
        nearDuplicateThreshold: Double = 0.62,
        conflictThreshold: Double = 0.45,
        matcher: any MemorySemanticMatcher = LexicalSemanticMatcher()
    ) {
        self.nearDuplicateThreshold = nearDuplicateThreshold
        self.conflictThreshold = conflictThreshold
        self.matcher = matcher
    }

    /// Classifies `candidate` against everything already stored.
    public func classify(
        _ candidate: MemoryItem,
        against existing: [MemoryItem]
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

            // Guard 1: a condition on one side and not the other. "During rush
            // hour" describes a different situation, whatever the word overlap.
            guard storedProfile.qualifiers == candidateProfile.qualifiers else { continue }

            let similarity = matcher.similarity(query: candidateProfile, memory: storedProfile)
            let sharedSubject = !storedProfile.terms.isDisjoint(with: candidateProfile.terms)
            let bothQuantified =
                !storedProfile.durations.isEmpty && !candidateProfile.durations.isEmpty
            let quantitiesAgree =
                bothQuantified && !storedProfile.durations.isDisjoint(with: candidateProfile.durations)
            let quantitiesDisagree =
                bothQuantified && storedProfile.durations.isDisjoint(with: candidateProfile.durations)

            // Guard 2: the same subject with a different number is a
            // disagreement, not a repetition. Someone's commute changed, or one
            // of the two is wrong — either way, discarding one silently is the
            // wrong answer.
            if quantitiesDisagree, sharedSubject, similarity >= conflictThreshold {
                if similarity > bestSimilarity {
                    best = .conflicting(existing: stored, similarity: similarity)
                    bestSimilarity = similarity
                }
                continue
            }

            // Two ways to be the same fact.
            //
            // The first is strong word overlap. The second exists because
            // lexical matching genuinely cannot see that "it takes me 30
            // minutes to drive to work" and "my commute to work is roughly half
            // an hour" are one statement — they share a single content word.
            // What connects them is that they are the same category, about the
            // same subject, and name the same quantity. Requiring all three
            // keeps the rule conservative; it is a stand-in for the semantic
            // matching a real embedding model would do, and it is the first
            // thing that should be replaced when one exists.
            let isSameFact = similarity >= nearDuplicateThreshold
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
