import AssistantDomain
import Foundation

/// What aging decided about one memory.
public struct MemoryAgingDecision: Hashable, Sendable {
    public var memory: MemoryItem
    public var lifecycle: MemoryLifecycle
    /// Why, in one phrase, for logs and tests. Never the memory's own text.
    public var reason: String

    public init(memory: MemoryItem, lifecycle: MemoryLifecycle, reason: String) {
        self.memory = memory
        self.lifecycle = lifecycle
        self.reason = reason
    }

    public var changesAnything: Bool { memory.lifecycle != lifecycle }
}

/// When a memory stops being worth carrying, and when it stops being worth
/// keeping in front of a model.
///
/// ## Forgetting, done carefully
///
/// The naive version is `if older than N days, delete`, and it is wrong in both
/// directions at once. It throws away the commute time someone told the app two
/// years ago — which is exactly the kind of thing a personal assistant exists to
/// remember — while keeping last month's guess about a café because it is
/// recent. Age on its own says nothing about worth.
///
/// So aging here reads six things, and age is only one of them: how the memory
/// was learned, how much it seemed to matter, how sure the app is, whether the
/// user has taken ownership of it, whether it belongs to something they still do
/// regularly, and only then how long it has sat there.
///
/// ## And it never deletes
///
/// The worst outcome is silently destroying something the user said. So the two
/// steps are `active → stale → archived`, both reversible, both visible in the
/// Memory screen, and neither is a delete. Deleting is a thing the user does.
public struct MemoryAgingPolicy: Hashable, Sendable {
    /// How long an inferred memory sits unused before it stops being retrieved.
    public var inferredStaleAfter: TimeInterval
    /// And how long before it is filed away.
    public var inferredArchiveAfter: TimeInterval

    /// The same for something the app watched the user do, rather than guessed.
    ///
    /// Longer, because a behaviour observed repeatedly is better evidence than
    /// a one-off inference — but still not something the user said.
    public var observedStaleAfter: TimeInterval
    public var observedArchiveAfter: TimeInterval

    /// How long an explicitly stated memory has to go unused and unimportant
    /// before it merely fades.
    ///
    /// Deliberately measured in years. Something a person typed or said in words
    /// is the strongest signal this app ever gets, and quietly retiring it after
    /// a few months would make the assistant worse the longer it knew someone —
    /// which is the opposite of the point.
    public var explicitStaleAfter: TimeInterval

    /// Below this, a memory is not important enough to protect on salience
    /// alone.
    public var lowSalience: Double

    /// Below this, the app is not sure enough of a memory to protect it.
    public var lowConfidence: Double

    /// The most that being used recently can postpone fading.
    ///
    /// Bounded on purpose — section 47. Without a cap, a memory that surfaced
    /// once would refresh its own lease every time it surfaced, and the ranking
    /// would spend forever defending its earliest guesses. Usage buys time; it
    /// does not buy permanence.
    public var usageGrace: TimeInterval

    public init(
        inferredStaleAfter: TimeInterval = TimeSpan.days(120),
        inferredArchiveAfter: TimeInterval = TimeSpan.days(365),
        observedStaleAfter: TimeInterval = TimeSpan.days(240),
        observedArchiveAfter: TimeInterval = TimeSpan.days(540),
        explicitStaleAfter: TimeInterval = TimeSpan.days(1_095),
        lowSalience: Double = 0.35,
        lowConfidence: Double = 0.7,
        usageGrace: TimeInterval = TimeSpan.days(60)
    ) {
        self.inferredStaleAfter = inferredStaleAfter
        self.inferredArchiveAfter = inferredArchiveAfter
        self.observedStaleAfter = observedStaleAfter
        self.observedArchiveAfter = observedArchiveAfter
        self.explicitStaleAfter = explicitStaleAfter
        self.lowSalience = lowSalience
        self.lowConfidence = lowConfidence
        self.usageGrace = usageGrace
    }

    public static let `default` = MemoryAgingPolicy()

    /// What should happen to this memory now.
    ///
    /// Pure, and a function of stored fields plus the clock — which is what
    /// makes running it twice a no-op the second time, and makes every case
    /// below assertable without waiting for a year to pass.
    public func decide(
        for memory: MemoryItem,
        now: Date,
        protectedEntityKeys: Set<String> = []
    ) -> MemoryAgingDecision {
        // Only the two states aging owns. Superseded and conflicting are
        // conclusions the app reached about *truth*, and time does not overturn
        // them; quietly archiving a superseded memory would also lose the
        // history the Memory screen shows.
        guard memory.lifecycle == .active || memory.lifecycle == .stale else {
            return keep(memory, "lifecycle is not aging's to change")
        }

        if memory.isProtected {
            return decision(memory, .active, "the user edited this")
        }

        // Something the user still does. A commute memory belonging to a live
        // routine is load-bearing however old it is — section 85.
        if !protectedEntityKeys.isEmpty,
           !Set(memory.entityKeys).isDisjoint(with: protectedEntityKeys) {
            return decision(memory, .active, "supports an active routine")
        }

        // A consolidated fact is the surviving summary of several statements.
        // Fading it would fade all of them at once, and its own timestamp is
        // the consolidation rather than the evidence.
        if memory.isConsolidated {
            return decision(memory, .active, "consolidated from several memories")
        }

        let age = effectiveAge(of: memory, now: now)

        if memory.source.isExplicit {
            // Never archived by age. The most it can do is stop being retrieved,
            // and only when it was never important and has gone years unused.
            let unimportant = memory.salience < lowSalience
            if unimportant, age >= explicitStaleAfter {
                return decision(memory, .stale, "stated long ago, low salience, unused")
            }
            return decision(memory, .active, "explicitly stated by the user")
        }

        let (staleAfter, archiveAfter) = thresholds(for: memory.source)

        // High salience or high confidence keeps an inference in play longer.
        // Both being low is what makes a memory a candidate for fading at all —
        // section 46's "weak inferred facts and low-salience stale details".
        let isWeak = memory.salience < lowSalience || memory.confidence < lowConfidence
        guard isWeak else {
            return decision(memory, .active, "inferred but salient and confident")
        }

        if age >= archiveAfter {
            return decision(memory, .archived, "unused inference, long past its threshold")
        }
        if age >= staleAfter {
            return decision(memory, .stale, "unused inference")
        }
        // Young again, because it was used. A stale memory can come back —
        // that is the whole reason `stale` is a step rather than a verdict.
        return decision(memory, .active, "recent enough")
    }

    // MARK: Detail

    private func thresholds(for source: MemorySource) -> (TimeInterval, TimeInterval) {
        switch source {
        case .observation:
            return (observedStaleAfter, observedArchiveAfter)
        case .assistant:
            return (inferredStaleAfter, inferredArchiveAfter)
        case .legacy:
            // Stored before the app recorded how it had been learned. Treated as
            // observed rather than inferred: the alternative is retiring
            // everything the assistant knew before that feature existed, on no
            // evidence at all.
            return (observedStaleAfter, observedArchiveAfter)
        case .user, .manual:
            return (explicitStaleAfter, .greatestFiniteMagnitude)
        }
    }

    /// Age since the memory last changed, less a bounded credit for being used.
    private func effectiveAge(of memory: MemoryItem, now: Date) -> TimeInterval {
        let age = max(0, now.timeIntervalSince(max(memory.updatedAt, memory.createdAt)))
        guard let lastUsedAt = memory.lastUsedAt else { return age }
        // How much later it was used than written, capped. A memory used the
        // day it was created earns nothing; one still being surfaced a year on
        // earns the full grace and no more.
        let credit = min(usageGrace, max(0, lastUsedAt.timeIntervalSince(memory.updatedAt)))
        return max(0, age - credit)
    }

    private func keep(_ memory: MemoryItem, _ reason: String) -> MemoryAgingDecision {
        MemoryAgingDecision(memory: memory, lifecycle: memory.lifecycle, reason: reason)
    }

    private func decision(
        _ memory: MemoryItem,
        _ lifecycle: MemoryLifecycle,
        _ reason: String
    ) -> MemoryAgingDecision {
        MemoryAgingDecision(memory: memory, lifecycle: lifecycle, reason: reason)
    }
}
