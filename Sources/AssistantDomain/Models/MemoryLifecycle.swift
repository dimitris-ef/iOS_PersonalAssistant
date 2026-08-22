import Foundation

/// Where a memory stands, short of being deleted.
///
/// ## Why this is not just a `Bool`
///
/// Because "not currently useful" and "gone" are different, and collapsing them
/// is how an assistant loses things people told it. A café the assistant guessed
/// at eighteen months ago should stop turning up in prompts; it should not
/// vanish from the Memory screen, because the user never asked for that and
/// might want it back. Equally, an old commute time that a newer one replaced is
/// history, not an error — showing both without saying which is current is the
/// failure this enum exists to prevent.
///
/// Only ``active`` memories reach a prompt. Everything else stays inspectable.
public enum MemoryLifecycle: String, Hashable, Codable, Sendable, CaseIterable {
    /// In use. The only state that reaches a model.
    case active

    /// Losing value with age, still eligible to be brought back by use.
    ///
    /// The waiting room rather than a verdict: a stale memory is excluded from
    /// retrieval but is one relevant question away from being active again. That
    /// two-step matters because aging is a guess about importance, and a guess
    /// that goes straight to archived has no chance to be wrong out loud.
    case stale

    /// Aged out. Kept, not retrieved, restorable by the user.
    case archived

    /// Replaced by a newer, better-sourced statement of the same fact.
    ///
    /// Distinct from `archived`, which is about time, and from deletion, which
    /// is the user's decision. A superseded memory is the *previous answer* to a
    /// question the user has since answered differently, and the Memory screen
    /// shows it as exactly that.
    case superseded

    /// Disagrees with something else and the app could not tell which is right.
    ///
    /// Deliberately reachable. When the evidence genuinely does not settle it,
    /// saying so and showing the user both is more honest than picking one and
    /// pretending. Excluded from prompts — handing a model two contradictory
    /// facts is an invitation to choose at random.
    case conflicting

    /// Whether a memory in this state may be sent to a model.
    public var isRetrievable: Bool { self == .active }

    /// Whether the user can bring this back with one tap.
    ///
    /// Superseded and conflicting memories are not "restorable" in this sense:
    /// there is nothing to restore them *to* while the thing that replaced them
    /// stands. The way back is to edit or delete the newer memory, which is a
    /// decision rather than an undo.
    public var isRestorable: Bool { self == .stale || self == .archived }

    /// A short label for the Memory screen.
    public var label: String {
        switch self {
        case .active: return "Current"
        case .stale: return "Fading"
        case .archived: return "Archived"
        case .superseded: return "Superseded"
        case .conflicting: return "Unresolved"
        }
    }
}

/// How one memory relates to another.
///
/// ## Deliberately not a knowledge graph
///
/// Six relations, one hop, no inference. The point is to answer two questions —
/// *what else is worth surfacing alongside this?* and *where did this
/// consolidated fact come from?* — not to represent the user's life as a graph.
/// A general graph would need a query language, cycle semantics, and a story for
/// what happens when an edge contradicts a memory; none of that buys the
/// assistant anything it cannot get from six typed edges.
public enum MemoryRelationType: String, Hashable, Codable, Sendable, CaseIterable {
    /// Two memories about the same part of someone's life.
    ///
    /// Symmetric and freely cyclic. "Work is 30 minutes away" relates to "I need
    /// 45 minutes to get ready", and a cycle between them is correct, not a bug.
    case relatedTo

    /// The target is the person the source is about.
    case aboutPerson

    /// The target is the place the source is about.
    case aboutPlace

    /// The source is evidence for the target.
    ///
    /// Directed and acyclic by construction: a consolidated fact is supported by
    /// its sources, never the other way round.
    case supports

    /// The source narrows or conditions the target.
    ///
    /// "Commute takes 45 minutes during rush hour" refines "commute takes 30
    /// minutes". The pair is the reason consolidation must not merge them.
    case refines

    /// The source disagrees with the target.
    case contradicts

    /// The source was produced from the target.
    ///
    /// The provenance edge. Directed, and the one relation where a cycle really
    /// is an error — a fact derived from itself is how consolidation starts
    /// eating its own output.
    case derivedFrom

    /// True when the relation means the same thing read backwards.
    public var isSymmetric: Bool {
        switch self {
        case .relatedTo, .contradicts: return true
        case .aboutPerson, .aboutPlace, .supports, .refines, .derivedFrom: return false
        }
    }

    /// True when a cycle through this relation is a bug rather than a fact.
    public var requiresAcyclic: Bool {
        switch self {
        case .derivedFrom, .supports: return true
        case .relatedTo, .aboutPerson, .aboutPlace, .refines, .contradicts: return false
        }
    }
}

/// One typed edge between two memories.
///
/// Identity is derived from the three things that define the edge — source,
/// target, type — rather than allocated. Maintenance runs repeatedly and would
/// otherwise add a second identical "supports" edge on every pass, which is the
/// same idempotency problem routine occurrences had in Part 8 and has the same
/// answer.
public struct MemoryRelation: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<MemoryRelation>

    public var id: ID
    public var source: MemoryItem.ID
    public var target: MemoryItem.ID
    public var type: MemoryRelationType
    /// How sure the app is that the relation holds (0...1).
    public var confidence: Double
    public var createdAt: Date

    public init(
        source: MemoryItem.ID,
        target: MemoryItem.ID,
        type: MemoryRelationType,
        confidence: Double = 0.8,
        createdAt: Date
    ) {
        self.id = Self.identity(source: source, target: target, type: type)
        self.source = source
        self.target = target
        self.type = type
        self.confidence = min(max(confidence, 0), 1)
        self.createdAt = createdAt
    }

    public static func identity(
        source: MemoryItem.ID,
        target: MemoryItem.ID,
        type: MemoryRelationType
    ) -> ID {
        ID.deterministic(
            namespace: "memory-relation/\(type.rawValue)",
            name: "\(source.rawValue.uuidString)>\(target.rawValue.uuidString)"
        )
    }

    /// The same edge the other way round, for symmetric types.
    public var reversed: MemoryRelation {
        MemoryRelation(
            source: target,
            target: source,
            type: type,
            confidence: confidence,
            createdAt: createdAt
        )
    }
}
