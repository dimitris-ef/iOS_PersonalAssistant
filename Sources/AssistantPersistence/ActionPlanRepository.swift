import AssistantDomain
import AssistantTools
import Foundation

/// What the assistant did, stored alongside what it said.
///
/// `Message.actionPlanID` already points from a reply to the plan it produced;
/// without somewhere to keep the plan, that pointer went nowhere after a
/// relaunch and the transcript quietly degraded to plain text — the event card,
/// the reminder timeline and the "simulated" badge all gone, with no indication
/// anything had been lost.
public struct ActionPlanRecord: Hashable, Sendable {
    public var plan: AssistantActionPlan
    public var results: [ToolResult]
    /// The conversation the plan belongs to, so a deleted conversation takes
    /// its action history with it.
    public var conversationID: Conversation.ID

    public init(
        plan: AssistantActionPlan,
        results: [ToolResult],
        conversationID: Conversation.ID
    ) {
        self.plan = plan
        self.results = results
        self.conversationID = conversationID
    }
}

/// Storage for executed action plans.
///
/// Deliberately narrow. Plans are written once when a turn completes and read
/// back when a conversation loads; they are never edited, so there is no update
/// operation and no way for history to be rewritten.
///
/// ## What is not stored
///
/// `AssistantActionPlan.rejected` — the calls the decoder refused — is **not**
/// persisted. It is turn-scoped diagnostics: it explains to the user, in the
/// moment, why something they asked for did not happen, and it is not part of
/// the historical record of what the assistant did. The transcript's cards are
/// built from `plan.actions` alone, so nothing in a restored conversation
/// depends on it.
public protocol ActionPlanRepository: Sendable {
    func save(_ record: ActionPlanRecord) async throws
    func record(id: ActionPlanID) async throws -> ActionPlanRecord?
    /// Every plan produced in one conversation, oldest first.
    func records(inConversation id: Conversation.ID) async throws -> [ActionPlanRecord]
}
