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
