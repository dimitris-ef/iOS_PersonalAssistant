import Foundation

/// The complete set of actions an AI model is allowed to ask for.
///
/// This lives in the domain layer because it is product vocabulary — settings,
/// authorization rules and audit records all refer to it. The typed inputs and
/// the decoding/validation live in `AssistantTools`; execution lives behind the
/// platform protocols. A model can never reach an OS API except by naming one
/// of these and passing validation.
public enum ToolKind: String, Hashable, Codable, Sendable, CaseIterable {
    case createCalendarEvent
    case updateCalendarEvent
    case deleteCalendarEvent
    case createReminder
    case completeReminder
    case createAlarm
    case updateAlarm
    case cancelAlarm
    case scheduleNotification
    case storeMemory
    case updateMemory
    case createTask
    case completeTask
    case createFollowUp
    case getUpcomingSchedule
    /// Set up a recurring responsibility — the definition, not one occurrence.
    case createRoutine
    /// Say that one task must happen before another.
    case addTaskDependency
    /// "Help me start." Produces the first concrete step and moves the task
    /// into progress. Never completes anything.
    case startTask
    /// Ask the user one focused question instead of guessing.
    ///
    /// The odd one out: it changes nothing, and the application never executes
    /// it. It is a tool because a tool call is the only structured channel a
    /// model has — the alternative is parsing prose for question marks, which
    /// is exactly the "behaviour must never depend on interpreting model prose"
    /// rule the tool layer exists to enforce. The engine intercepts it and ends
    /// the turn asking, without running the side-effecting calls proposed
    /// alongside it.
    case askClarification

    /// Read-only tools are safe to run without confirmation.
    public var isReadOnly: Bool {
        switch self {
        case .getUpcomingSchedule, .askClarification:
            return true
        default:
            return false
        }
    }

    /// Tools that reach outside the app and are visible to the user.
    public var affectsSystemState: Bool {
        switch self {
        case .createCalendarEvent, .updateCalendarEvent, .deleteCalendarEvent,
             .createReminder, .completeReminder,
             .createAlarm, .updateAlarm, .cancelAlarm,
             .scheduleNotification:
            return true
        case .storeMemory, .updateMemory, .createTask, .completeTask,
             .createFollowUp, .getUpcomingSchedule, .askClarification,
             .createRoutine, .addTaskDependency, .startTask:
            return false
        }
    }
}

extension ToolKind {
    /// What the action does, as a person would say it: "add a reminder".
    ///
    /// For the sentence under a reply. `createReminder` is a wire name, and
    /// build 20 showed it to the user verbatim ("1 action completed:
    /// createReminder").
    public var plainAction: String {
        switch self {
        case .createCalendarEvent: return "add a calendar event"
        case .updateCalendarEvent: return "change a calendar event"
        case .deleteCalendarEvent: return "delete a calendar event"
        case .createReminder: return "add a reminder"
        case .completeReminder: return "complete a reminder"
        case .createAlarm: return "set an alarm"
        case .updateAlarm: return "change an alarm"
        case .cancelAlarm: return "cancel an alarm"
        case .scheduleNotification: return "schedule a notification"
        case .storeMemory: return "remember something"
        case .updateMemory: return "update a memory"
        case .createTask: return "add a task"
        case .completeTask: return "complete a task"
        case .createFollowUp: return "add a follow-up"
        case .getUpcomingSchedule: return "check your schedule"
        case .createRoutine: return "set up a routine"
        case .addTaskDependency: return "link two tasks"
        case .startTask: return "start a task"
        case .askClarification: return "ask a question"
        }
    }

    /// The same, done: "added a reminder".
    public var plainActionDone: String {
        switch self {
        case .createCalendarEvent: return "added a calendar event"
        case .updateCalendarEvent: return "changed a calendar event"
        case .deleteCalendarEvent: return "deleted a calendar event"
        case .createReminder: return "added a reminder"
        case .completeReminder: return "completed a reminder"
        case .createAlarm: return "set an alarm"
        case .updateAlarm: return "changed an alarm"
        case .cancelAlarm: return "cancelled an alarm"
        case .scheduleNotification: return "scheduled a notification"
        case .storeMemory: return "remembered that"
        case .updateMemory: return "updated a memory"
        case .createTask: return "added a task"
        case .completeTask: return "completed a task"
        case .createFollowUp: return "added a follow-up"
        case .getUpcomingSchedule: return "checked your schedule"
        case .createRoutine: return "set up a routine"
        case .addTaskDependency: return "linked two tasks"
        case .startTask: return "started a task"
        case .askClarification: return "asked a question"
        }
    }
}

/// Whether a tool may run, and under what conditions.
public enum ToolAuthorization: String, Hashable, Codable, Sendable, CaseIterable {
    case allowed
    /// Prepared and shown to the user, executed only on explicit approval.
    case requiresConfirmation
    case denied
}
