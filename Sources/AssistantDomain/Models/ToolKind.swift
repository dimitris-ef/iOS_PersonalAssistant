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
             .createFollowUp, .getUpcomingSchedule, .askClarification:
            return false
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
