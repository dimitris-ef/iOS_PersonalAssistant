import Foundation

/// A UUID-backed identifier that is typed by the thing it identifies.
///
/// Using `Identifier<TaskItem>` rather than a bare `UUID` makes it impossible
/// to hand a task id to something expecting a calendar item id, which matters
/// once the assistant starts wiring reminders, tasks and events together.
public struct Identifier<Subject>: Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String { rawValue.uuidString }

    /// An identifier derived from what a thing *is* rather than allocated at
    /// random.
    ///
    /// ## Why this exists
    ///
    /// A recurring routine's Thursday occurrence has to have the same identity
    /// every time the app works out that Thursday needs one — on launch, on
    /// foreground, after a crash, twice in the same second. With a random id,
    /// "have I already made this?" needs a query, the query needs an index on
    /// two columns, and the moment the query is missed the user has two sets of
    /// bin reminders. Deriving the id from the routine and the scheduled moment
    /// makes the second attempt write over the first, which is the outcome we
    /// wanted from the query anyway.
    ///
    /// Not a cryptographic hash and not RFC 4122 version 5 — nothing here is
    /// defending against an adversary choosing a colliding name, and pulling in
    /// CryptoKit for a primary key would be the wrong trade. Two independently
    /// seeded 64-bit FNV-1a passes give 128 bits that are stable across
    /// processes, which is the only property being relied on. (`Hasher` is not
    /// stable across processes, which is exactly why it cannot be used here.)
    public static func deterministic(namespace: String, name: String) -> Identifier<Subject> {
        let text = "\(namespace)\u{1F}\(name)"
        var bytes = withUnsafeBytes(of: fnv1a(text, seed: 0xcbf2_9ce4_8422_2325).bigEndian) { Array($0) }
        bytes += withUnsafeBytes(of: fnv1a(text, seed: 0x9e37_79b9_7f4a_7c15).bigEndian) { Array($0) }

        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return Identifier(UUID(uuid: uuid))
    }

    private static func fnv1a(_ text: String, seed: UInt64) -> UInt64 {
        // The prime is eleven hex digits; written ungrouped because splitting it
        // into fours inserts a zero and silently changes the constant.
        let prime: UInt64 = 0x100000001b3
        var hash = seed
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

extension Identifier: Equatable {
    public static func == (lhs: Identifier<Subject>, rhs: Identifier<Subject>) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

extension Identifier: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

extension Identifier: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Phantom tag for identifiers whose subject type lives in another module.
public enum ActionPlanSubject {}
/// Identifier for an ``AssistantActionPlan`` (defined in `AssistantTools`).
public typealias ActionPlanID = Identifier<ActionPlanSubject>

/// Phantom tag for tool-call identifiers.
public enum ToolCallSubject {}
/// Identifier for a single tool call proposed by an AI provider.
public typealias ToolCallID = Identifier<ToolCallSubject>
