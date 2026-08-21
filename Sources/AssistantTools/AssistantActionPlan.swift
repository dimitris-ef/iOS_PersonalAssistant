import AssistantDomain
import Foundation

/// Who asked for an action.
///
/// Actions the support planner adds are marked as such so the user can tell
/// "the model decided this" from "the app's reminder strategy decided this".
public enum ActionOrigin: String, Hashable, Codable, Sendable {
    case model
    case supportPlanner
    case user
    case automation
}

/// `Codable` so an executed action can be written to the conversation history
/// and read back to rebuild its card. The plan it belongs to is not `Codable`:
/// its `rejected` list is turn-scoped and deliberately not persisted.
public struct AssistantAction: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<AssistantAction>

    public var id: ID
    public var request: ToolRequest
    public var origin: ActionOrigin
    public var authorization: ToolAuthorization
    /// Why this action exists, in one line, for display in the plan preview.
    public var rationale: String?
    /// The model tool call this came from, when it came from one.
    public var sourceCallID: ToolCallID?

    public init(
        id: ID = ID(),
        request: ToolRequest,
        origin: ActionOrigin,
        authorization: ToolAuthorization,
        rationale: String? = nil,
        sourceCallID: ToolCallID? = nil
    ) {
        self.id = id
        self.request = request
        self.origin = origin
        self.authorization = authorization
        self.rationale = rationale
        self.sourceCallID = sourceCallID
    }

    public var kind: ToolKind { request.kind }
}

/// The full set of actions produced by one turn, before execution.
///
/// Keeping the plan as a value means the UI can show it, the user can approve
/// or reject parts of it, and tests can assert on it without anything running.
public struct AssistantActionPlan: Identifiable, Hashable, Sendable {
    public typealias ID = ActionPlanID

    public var id: ID
    public var actions: [AssistantAction]
    public var rejected: [RejectedToolCall]
    public var createdAt: Date

    public init(
        id: ID = ID(),
        actions: [AssistantAction] = [],
        rejected: [RejectedToolCall] = [],
        createdAt: Date
    ) {
        self.id = id
        self.actions = actions
        self.rejected = rejected
        self.createdAt = createdAt
    }

    public var isEmpty: Bool { actions.isEmpty }

    public var executableActions: [AssistantAction] {
        actions.filter { $0.authorization == .allowed }
    }

    public var actionsAwaitingConfirmation: [AssistantAction] {
        actions.filter { $0.authorization == .requiresConfirmation }
    }
}

/// What happened when an action was executed.
public enum ToolOutcome: Hashable, Codable, Sendable {
    /// Really happened on the device.
    case executed
    /// Recorded by a mock service. The named platform did *not* do anything.
    case simulated(platform: String)
    /// Held back pending user approval.
    case awaitingConfirmation
    case denied(reason: String)
    case failed(reason: String)
    /// The current platform layer cannot do this yet.
    case unsupported(reason: String)

    public var didChangeAnything: Bool {
        switch self {
        case .executed, .simulated: return true
        case .awaitingConfirmation, .denied, .failed, .unsupported: return false
        }
    }
}

public struct ToolResult: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<ToolResult>

    public var id: ID
    public var actionID: AssistantAction.ID
    public var kind: ToolKind
    public var outcome: ToolOutcome
    /// Human-readable line describing what happened, e.g.
    /// "Calendar event created: Haircut — Sunday 22:00".
    public var message: String
    public var producedAt: Date
    /// Why it did not work, when it did not.
    ///
    /// `outcome` says *that* something failed and carries a sentence about it;
    /// this says which kind of failure it was, which is what the retry policy
    /// and the model's next decision are made from. Nil whenever the outcome is
    /// a success — a category is a fact about failures only.
    public var failure: ToolFailureCategory?

    public init(
        id: ID = ID(),
        actionID: AssistantAction.ID,
        kind: ToolKind,
        outcome: ToolOutcome,
        message: String,
        producedAt: Date,
        failure: ToolFailureCategory? = nil
    ) {
        self.id = id
        self.actionID = actionID
        self.kind = kind
        self.outcome = outcome
        self.message = message
        self.producedAt = producedAt
        self.failure = failure
    }
}
