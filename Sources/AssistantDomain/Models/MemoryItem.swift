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

    public init(
        id: ID = ID(),
        kind: MemoryKind,
        content: String,
        salience: Double = 0.5,
        tags: [String] = [],
        createdAt: Date,
        updatedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        source: MemorySource = .assistant
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
    }
}

public enum MemorySource: String, Hashable, Codable, Sendable {
    /// The user stated it explicitly ("remember that ...").
    case user
    /// The assistant inferred and stored it.
    case assistant
    /// Derived from observed behaviour (e.g. repeated snoozing).
    case observation
}

/// Query used to pull relevant memories into assistant context.
public struct MemoryQuery: Hashable, Sendable {
    public var text: String?
    public var kinds: Set<MemoryKind>
    public var tags: [String]
    public var limit: Int

    public init(
        text: String? = nil,
        kinds: Set<MemoryKind> = [],
        tags: [String] = [],
        limit: Int = 10
    ) {
        self.text = text
        self.kinds = kinds
        self.tags = tags
        self.limit = limit
    }
}
