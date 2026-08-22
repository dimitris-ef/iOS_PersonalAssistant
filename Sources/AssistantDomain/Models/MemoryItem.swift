import Foundation

public enum MemoryKind: String, Hashable, Codable, Sendable, CaseIterable {
    /// "I normally need 30 minutes to get ready."
    case routine
    /// "Don't wake me before 8 on weekends."
    case preference
    /// "My dentist is Dr. Alvarez."
    case person
    /// "Work is about 30 minutes away by bus."
    ///
    /// Distinct from `fact` because travel time to a named place feeds directly
    /// into leave-time planning.
    case place
    /// "Rent is due on the 1st."
    case recurringCommitment
    /// Anything else worth carrying forward.
    case fact
}

/// A single durable thing the assistant knows about the user.
///
/// Memory is long-lived and provider-independent. Providers receive a selected
/// subset as context; they never own or store it.
public struct MemoryItem: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<MemoryItem>

    public var id: ID
    public var kind: MemoryKind
    public var content: String
    /// How strongly this should be preferred when context space is limited (0...1).
    public var salience: Double
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var source: MemorySource

    /// How sure the application is that this is true (0...1).
    ///
    /// Distinct from ``salience``, and the two are often opposites. "My
    /// girlfriend's name is Anna" is near-certain and rarely relevant;
    /// "probably prefers evening workouts", inferred from three data points, is
    /// worth acting on but might be wrong. Ranking needs both: salience asks
    /// *does this matter*, confidence asks *is it even true*.
    ///
    /// Defaults from ``MemorySource`` rather than being guessed at each call
    /// site — how a memory was learned is the best available evidence of how
    /// much to trust it.
    public var confidence: Double

    /// Where this stands: in use, fading, archived, superseded, unresolved.
    ///
    /// Only ``MemoryLifecycle/active`` memories reach a prompt. Everything else
    /// stays in the store and stays visible to the user — see
    /// ``MemoryLifecycle``.
    public var lifecycle: MemoryLifecycle

    /// Coarse handles for the recurring things a memory is about.
    ///
    /// Strings like `place:work` or `person:dr_smith`, normalised at the point
    /// they are derived. They are a *hint*, never a requirement: retrieval works
    /// on memories that carry none, and nothing may depend on an entity having
    /// been recognised. What they buy is grouping — two memories about work can
    /// be told apart from two memories that merely both mention Tuesday — which
    /// helps consolidation and conflict detection avoid comparing unrelated
    /// things.
    ///
    /// Not an address book. There is no `Person` record behind `person:dr_smith`
    /// and there is not meant to be.
    public var entityKeys: [String]

    /// The memories this one was consolidated from, if it was.
    ///
    /// Provenance, kept on the item as well as in the relation graph, because
    /// "based on 3 similar memories" is something the Memory screen shows and
    /// should not need a graph query to render. The relations carry the same
    /// facts for anything that needs to walk them.
    public var consolidatedFrom: [MemoryItem.ID]

    /// True when the user has taken ownership of this exact wording.
    ///
    /// Set when someone edits a memory by hand. Maintenance leaves protected
    /// memories alone: consolidation will not rewrite them from their old
    /// sources, and aging will not fade them. Editing a fact is the clearest
    /// statement of interest a user can make, and a maintenance pass that
    /// overwrote it on the next launch would be the app arguing with them.
    public var isProtected: Bool

    public init(
        id: ID = ID(),
        kind: MemoryKind,
        content: String,
        salience: Double = 0.5,
        tags: [String] = [],
        createdAt: Date,
        updatedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        source: MemorySource = .assistant,
        confidence: Double? = nil,
        lifecycle: MemoryLifecycle = .active,
        entityKeys: [String] = [],
        consolidatedFrom: [MemoryItem.ID] = [],
        isProtected: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.salience = min(max(salience, 0), 1)
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
        self.source = source
        self.confidence = min(max(confidence ?? source.defaultConfidence, 0), 1)
        self.lifecycle = lifecycle
        self.entityKeys = entityKeys
        self.consolidatedFrom = consolidatedFrom
        self.isProtected = isProtected
    }

    /// True when this memory may be sent to a model.
    public var isRetrievable: Bool { lifecycle.isRetrievable }

    /// True when this was produced by consolidating others.
    public var isConsolidated: Bool { !consolidatedFrom.isEmpty }
}

/// Where a memory came from.
///
/// Kept provider-independent on purpose: "the user typed this" and "the
/// assistant worked it out" are facts about the application's relationship with
/// the user, not about which model happened to be selected.
public enum MemorySource: String, Hashable, Codable, Sendable, CaseIterable {
    /// The user stated it explicitly in conversation ("remember that ...").
    case user
    /// The user typed it into the Memory screen themselves.
    case manual
    /// The assistant inferred and stored it.
    case assistant
    /// Derived from observed behaviour (e.g. repeated snoozing).
    case observation
    /// Stored before the application recorded how it had been learned.
    ///
    /// Only ever produced by migration. Trusted enough not to vanish from
    /// ranking, because the alternative — treating everything from before this
    /// feature as doubtful — would quietly discard what the assistant already
    /// knew about someone.
    case legacy

    /// How much to trust a memory from this source, before anything else is
    /// known about it.
    ///
    /// Centralised here rather than at each call site so "how confident are we
    /// in an inferred memory?" has one answer that a test can pin and a person
    /// can argue with.
    public var defaultConfidence: Double {
        switch self {
        case .user: return 0.95
        case .manual: return 1.0
        case .observation: return 0.75
        case .assistant: return 0.6
        case .legacy: return 0.8
        }
    }

    /// True when the user said it themselves, in words.
    ///
    /// The tiebreak when two memories disagree: what someone told you outranks
    /// what you worked out about them.
    public var isExplicit: Bool {
        self == .user || self == .manual
    }
}

/// Query used to pull relevant memories into assistant context.
public struct MemoryQuery: Hashable, Sendable {
    public var text: String?
    public var kinds: Set<MemoryKind>
    public var tags: [String]
    /// Which lifecycle states may be returned.
    ///
    /// Defaults to `[.active]`, so every existing caller keeps archived and
    /// superseded memories out of prompts without knowing the concept exists.
    /// The Memory screen widens it deliberately — that is what makes history
    /// inspectable rather than merely retained.
    public var lifecycles: Set<MemoryLifecycle>
    public var limit: Int
    /// The moment to measure recency against.
    ///
    /// Optional, and the ranker skips the recency factor when it is absent, so
    /// no repository has to reach for `Date()` to answer a query. Callers that
    /// care about recency — the context assembler does — supply their clock.
    public var now: Date?

    public init(
        text: String? = nil,
        kinds: Set<MemoryKind> = [],
        tags: [String] = [],
        lifecycles: Set<MemoryLifecycle> = [.active],
        limit: Int = 10,
        now: Date? = nil
    ) {
        self.text = text
        self.kinds = kinds
        self.tags = tags
        self.lifecycles = lifecycles
        self.limit = limit
        self.now = now
    }

    /// Every state, for the Memory screen and for maintenance.
    public static let everyLifecycle = Set(MemoryLifecycle.allCases)
}
