import AssistantDomain
import Foundation

public enum AIMessageRole: String, Hashable, Codable, Sendable {
    case system
    case user
    case assistant
    /// Carries the outcome of a tool call back to the model.
    case tool
}

/// A message as seen by an AI provider.
///
/// Deliberately separate from the domain ``Message``: the transcript the user
/// owns and the transcript a model sees are different things, and only the
/// former is persisted.
public struct AIMessage: Hashable, Codable, Sendable {
    public var role: AIMessageRole
    public var content: String
    /// Present on `.tool` messages: which call this is answering.
    public var toolCallID: ToolCallID?

    public init(role: AIMessageRole, content: String, toolCallID: ToolCallID? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
    }
}

/// A tool invocation proposed by a model, still untyped and unvalidated.
///
/// The application never acts on this directly — `AssistantTools` decodes it
/// into a typed request first, and anything that fails to decode is discarded.
public struct AIToolCall: Hashable, Codable, Sendable {
    public var id: ToolCallID
    public var name: String
    public var arguments: JSONValue

    public init(id: ToolCallID = ToolCallID(), name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// A tool the model is told it may call.
///
/// Providers translate this into their own tool-definition format. The
/// application-level tool catalogue produces these; the AI layer knows nothing
/// about what any particular tool does.
public struct AIToolSchema: Hashable, Codable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONSchema

    public init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}
