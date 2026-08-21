import AssistantDomain
import AssistantTools
import Foundation

/// A structured result shown inside the conversation.
///
/// The set of cases is open by design — new assistant capabilities (routines,
/// automations, travel plans) become new cases plus one new view, without
/// touching the message list. `unsupported` guarantees a capability never
/// silently disappears from the transcript just because its card is unwritten.
enum AssistantActionPresentation: Identifiable, Equatable {
    case calendarEvent(EventActionModel)
    case task(TaskActionModel)
    case alarm(AlarmActionModel)
    case memory(MemoryActionModel)
    case reminderPlan(ReminderPlanPresentation)
    case unsupported(GenericActionModel)

    var id: AssistantAction.ID {
        switch self {
        case .calendarEvent(let model): return model.id
        case .task(let model): return model.id
        case .alarm(let model): return model.id
        case .memory(let model): return model.id
        case .reminderPlan(let model): return AssistantAction.ID(model.id.rawValue)
        case .unsupported(let model): return model.id
        }
    }
}

struct EventActionModel: Identifiable, Equatable {
    let id: AssistantAction.ID
    let eventID: CalendarItem.ID?
    let title: String
    /// "Sunday · 10:00 PM"
    let whenLabel: String
    let location: String?
    /// The support plan generated alongside the event, when there is one.
    let reminderPlan: ReminderPlanPresentation?
    let fidelity: ActionFidelity
}

struct TaskActionModel: Identifiable, Equatable {
    let id: AssistantAction.ID
    let taskID: TaskItem.ID?
    let title: String
    let timingLabel: String
    let reminderPlan: ReminderPlanPresentation?
    let fidelity: ActionFidelity
}

struct AlarmActionModel: Identifiable, Equatable {
    let id: AssistantAction.ID
    let label: String
    let whenLabel: String
    let allowsSnooze: Bool
    let fidelity: ActionFidelity
}

struct MemoryActionModel: Identifiable, Equatable {
    let id: AssistantAction.ID
    let content: String
    let kind: MemoryKind
    let fidelity: ActionFidelity
}

struct GenericActionModel: Identifiable, Equatable {
    let id: AssistantAction.ID
    let title: String
    let detail: String
    let fidelity: ActionFidelity
}

/// Whether an action really happened, said plainly.
///
/// Carried into the UI so a card can never imply an iPhone did something it
/// did not. Derived from `ToolOutcome`, which is derived from
/// `PlatformFidelity` — the honesty travels the whole way up.
enum ActionFidelity: Equatable {
    /// Changed real application state (memory, tasks).
    case applied
    /// Recorded by a mock service. No device was involved.
    case simulated(platform: String)
    case awaitingConfirmation
    case blocked(reason: String)

    var isSimulated: Bool {
        if case .simulated = self { return true }
        return false
    }
}

/// Turns an executed action plan into the cards shown under a reply.
///
/// Reminder stages the support planner added are folded into the card for the
/// thing they support, rather than listed as four separate notifications. That
/// grouping is the design: the user should see "a haircut, and here is how I'll
/// help you get there", not a log.
struct ConversationPresenter {
    let now: Date
    let calendar: Calendar
    var formatters: AppFormatters = .shared

    func present(
        plan: AssistantActionPlan,
        results: [ToolResult],
        reminderPlans: [ReminderPlan]
    ) -> [AssistantActionPresentation] {
        let resultsByAction = Dictionary(
            results.map { ($0.actionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Only the model's own requests become cards. Planner-added reminders
        // are shown inside those cards.
        return plan.actions
            .filter { $0.origin != .supportPlanner }
            .compactMap { action in
                present(
                    action: action,
                    result: resultsByAction[action.id],
                    reminderPlans: reminderPlans
                )
            }
    }

    private func present(
        action: AssistantAction,
        result: ToolResult?,
        reminderPlans: [ReminderPlan]
    ) -> AssistantActionPresentation? {
        let fidelity = ActionFidelity(result: result)

        switch action.request {
        case .createCalendarEvent(let input):
            let planPresentation = input.eventID
                .flatMap { id in
                    reminderPlans.first { $0.subject.reference == .calendarItem(id) }
                }
                .map { ReminderPlanPresentation.make(from: $0, now: now, calendar: calendar) }

            return .calendarEvent(
                EventActionModel(
                    id: action.id,
                    eventID: input.eventID,
                    title: input.title,
                    whenLabel: formatters.relativeDayAndTime(input.start, now: now),
                    location: input.location,
                    reminderPlan: planPresentation,
                    fidelity: fidelity
                )
            )

        case .createTask(let input):
            let planPresentation = input.taskID
                .flatMap { id in reminderPlans.first { $0.subject.reference == .task(id) } }
                .map { ReminderPlanPresentation.make(from: $0, now: now, calendar: calendar) }

            return .task(
                TaskActionModel(
                    id: action.id,
                    taskID: input.taskID,
                    title: input.title,
                    timingLabel: timingLabel(for: input),
                    reminderPlan: planPresentation,
                    fidelity: fidelity
                )
            )

        case .createAlarm(let input):
            return .alarm(
                AlarmActionModel(
                    id: action.id,
                    label: input.label,
                    whenLabel: formatters.relativeDayAndTime(input.fireDate, now: now),
                    allowsSnooze: input.allowsSnooze ?? true,
                    fidelity: fidelity
                )
            )

        case .storeMemory(let input):
            return .memory(
                MemoryActionModel(
                    id: action.id,
                    content: input.content,
                    kind: input.kind,
                    fidelity: fidelity
                )
            )

        case .createReminder(let input):
            return .unsupported(
                GenericActionModel(
                    id: action.id,
                    title: "Reminder added",
                    detail: input.title,
                    fidelity: fidelity
                )
            )

        case .getUpcomingSchedule, .askClarification:
            // Neither produces a card. A read's answer is the assistant's text,
            // and a clarification *is* the assistant's text — it is not an
            // action, and showing it as one would put an empty result row under
            // a question.
            return nil

        default:
            return .unsupported(
                GenericActionModel(
                    id: action.id,
                    title: action.kind.rawValue,
                    detail: result?.message ?? action.request.summary,
                    fidelity: fidelity
                )
            )
        }
    }

    private func timingLabel(for input: CreateTaskInput) -> String {
        if let fixed = input.fixedDate {
            return formatters.relativeDayAndTime(fixed, now: now)
        }
        if let window = input.flexibleWindow {
            return "Any time before \(formatters.relativeDay(window.end, now: now))"
        }
        if let due = input.dueDate {
            return "By \(formatters.relativeDayAndTime(due, now: now))"
        }
        return "No time set"
    }
}

extension ActionFidelity {
    init(result: ToolResult?) {
        guard let result else {
            self = .blocked(reason: "Not executed")
            return
        }
        switch result.outcome {
        case .executed:
            self = .applied
        case .simulated(let platform):
            self = .simulated(platform: platform)
        case .awaitingConfirmation:
            self = .awaitingConfirmation
        case .denied(let reason):
            self = .blocked(reason: reason)
        case .failed(let reason):
            self = .blocked(reason: reason)
        case .unsupported(let reason):
            self = .blocked(reason: reason)
        }
    }
}
