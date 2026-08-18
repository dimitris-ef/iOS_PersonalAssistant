import Foundation

/// How alike two pieces of text are, from 0 to 1.
///
/// The extension point for real semantic search. Today the only implementation
/// is lexical, but everything above this protocol — the ranker, the retrieval
/// service, `ContextAssembler`, the providers — is written against the
/// protocol, so an on-device embedding model becomes a new conformance and
/// nothing else changes.
///
/// Three constraints any future implementation must honour, because the
/// assistant's memory cannot depend on them being met:
///
/// - **No network.** Retrieval runs before every turn, including offline ones.
/// - **No API key.** Memory must work with the Apple and local providers, and
///   in CI, where there is no credential of any kind.
/// - **A synchronous answer.** Ranking a few hundred memories happens inside
///   assembling one request; it cannot become a second round trip.
///
/// An embedding matcher satisfying those would precompute vectors when a memory
/// is written and compare them here. See `Docs/MEMORY.md`.
public protocol MemorySemanticMatcher: Sendable {
    func similarity(query: MemoryTextProfile, memory: MemoryTextProfile) -> Double
}

/// The default matcher: term overlap, weighted by rarity, plus phrase bonuses.
///
/// Deliberately not "keyword contains". Four things lift it above exact
/// overlap, and each earns its place on the milestone's own examples:
///
/// - **Normalisation and stemming**, so "leaving for work" finds "it takes 30
///   minutes to drive to work".
/// - **Directional coverage**: what matters is how much of the *query* the
///   memory explains, not how much of a long memory the query happens to cover.
///   Otherwise verbose memories are punished for being detailed.
/// - **Bigram bonus**, so "get ready" beats a memory that merely mentions
///   "ready" and "get" separately.
/// - **A shared-duration bonus**, because "how long" questions and memories
///   about durations are usually about the same thing.
public struct LexicalSemanticMatcher: MemorySemanticMatcher {
    private let bigramBonus: Double
    private let durationBonus: Double

    public init(bigramBonus: Double = 0.2, durationBonus: Double = 0.1) {
        self.bigramBonus = bigramBonus
        self.durationBonus = durationBonus
    }

    public func similarity(query: MemoryTextProfile, memory: MemoryTextProfile) -> Double {
        guard !query.isEmpty, !memory.isEmpty else { return 0 }

        let shared = query.terms.intersection(memory.terms)
        guard !shared.isEmpty else { return 0 }

        // Coverage of the query, not of the memory. A one-line memory that
        // answers the question should not lose to a rambling one.
        let coverage = Double(shared.count) / Double(query.terms.count)

        // Overlap relative to the union, to stop a memory that repeats every
        // common word from scoring well on all of them.
        let union = query.terms.union(memory.terms).count
        let jaccard = Double(shared.count) / Double(union)

        var score = coverage * 0.7 + jaccard * 0.3

        if !query.bigrams.isEmpty {
            let sharedPhrases = query.bigrams.intersection(memory.bigrams)
            if !sharedPhrases.isEmpty {
                score += bigramBonus * Double(sharedPhrases.count) / Double(query.bigrams.count)
            }
        }

        if !query.durations.isEmpty, !memory.durations.isEmpty {
            score += durationBonus
        }

        return min(max(score, 0), 1)
    }
}
