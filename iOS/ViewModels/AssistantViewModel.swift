import AssistantDomain
import AssistantTools
import Foundation
import Observation

/// Screen state for the Assistant.
///
/// Holds only what belongs to this screen — the draft and the derived
/// conversation turns. Voice state belongs to `VoiceCoordinator`, which the
/// whole app shares, because a spoken request that outlives this screen still
/// has to finish. Shared data and every state change live
/// in `AppModel`, which is passed in rather than captured, so the view model
/// has no lifetime tied to the app graph.
@MainActor
@Observable
final class AssistantViewModel {
    var draft: String = ""

    /// The id to scroll to after new content arrives.
    private(set) var scrollTarget: Message.ID?

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Suggestions are for getting started, so they disappear once there is a
    /// real conversation to look at.
    func showsSuggestions(for conversation: Conversation) -> Bool {
        conversation.messages.count <= 4
    }

    func send(using model: AppModel) async {
        let text = draft
        draft = ""
        await model.send(text)
        scrollTarget = model.conversation.messages.last?.id
    }

    func applySuggestion(_ prompt: String) {
        draft = prompt
    }

    func scrollToLatest(in conversation: Conversation) {
        scrollTarget = conversation.messages.last?.id
    }

    // MARK: Turn presentation

    /// A message plus whatever the assistant actually did, ready to render.
    struct Turn: Identifiable {
        let message: Message
        let actions: [AssistantActionPresentation]

        var id: Message.ID { message.id }
    }

    func turns(for model: AppModel) -> [Turn] {
        let presenter = ConversationPresenter(now: model.now, calendar: model.calendar)

        return model.conversation.messages.map { message in
            guard
                let planID = message.actionPlanID,
                let plan = model.actionPlans[planID]
            else {
                return Turn(message: message, actions: [])
            }

            return Turn(
                message: message,
                actions: presenter.present(
                    plan: plan,
                    results: model.toolResults[planID] ?? [],
                    reminderPlans: model.reminderPlans
                )
            )
        }
    }
}
