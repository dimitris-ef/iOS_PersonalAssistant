import AssistantDomain
import Foundation

/// A reminder presented inside the app so the response flow can be exercised.
///
/// This is a **simulation**, not an iOS notification. Nothing is registered
/// with the system: the sheet is drawn by the app while it is in the
/// foreground, and it disappears when the app does. Real delivery — including
/// the Done/Snooze actions that make confirmation possible while the app is
/// closed — arrives with UserNotifications. TODO-XCODE.
struct SimulatedReminder: Identifiable, Equatable {
    enum Subject: Equatable {
        case task(TaskItem.ID)
        case event(CalendarItem.ID)
    }

    let id = UUID()
    let title: String
    let body: String
    let subject: Subject
    let stageKind: ReminderStageKind
    let escalation: EscalationLevel
    /// When true, dismissing must not be read as completion.
    let requiresConfirmation: Bool

    /// Builds a simulation from a real plan stage, so what the sheet shows is
    /// what the planner actually scheduled.
    static func from(
        stage: ReminderStage,
        plan: ReminderPlan,
        anchor: Date,
        formatter: RelativeTimeFormatting
    ) -> SimulatedReminder {
        let subject: Subject
        switch plan.subject.reference {
        case .task(let id):
            subject = .task(id)
        case .calendarItem(let id):
            subject = .event(id)
        case .freeform:
            subject = .event(CalendarItem.ID())
        }

        return SimulatedReminder(
            title: stage.message,
            body: formatter.anchorSentence(for: plan.subject.title, at: anchor),
            subject: subject,
            stageKind: stage.kind,
            escalation: stage.escalation,
            requiresConfirmation: stage.requiresConfirmation
                || plan.completion.requiresExplicitConfirmation
        )
    }
}

/// How the user answered a simulated reminder.
///
/// `dismiss` is deliberately separate from `completed`. Collapsing them into
/// one boolean is exactly the mistake the product exists to avoid.
enum SimulatedReminderResponse {
    /// "I'm doing it" — acknowledged and started.
    case doingIt
    /// "It's done" — explicit confirmation, the only thing that completes.
    case completed
    case snooze
    /// Swiped away. Acknowledgement only.
    case dismiss
}

/// Small seam so `SimulatedReminder` can build a sentence without importing
/// the formatting layer's concrete type.
protocol RelativeTimeFormatting {
    func anchorSentence(for title: String, at date: Date) -> String
}
