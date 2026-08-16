import AssistantDomain
import Foundation

/// A validated, typed request for one tool.
///
/// Nothing in the application acts on model output until it has become one of
/// these. That is the security boundary described in the architecture doc: the
/// model proposes, the decoder types it, the policy authorizes it, and only
/// then does a service execute it.
///
/// `Codable` because an executed request is also a historical record: the
/// action cards under a reply are rebuilt from stored requests when a
/// conversation is loaded. Every input type is already `Codable`, so the
/// conformance is synthesised. It grants no new authority — decoding produces a
/// request, and a request still has to go through authorization before anything
/// runs.
public enum ToolRequest: Hashable, Codable, Sendable {
    case createCalendarEvent(CreateCalendarEventInput)
    case updateCalendarEvent(UpdateCalendarEventInput)
    case deleteCalendarEvent(DeleteCalendarEventInput)
    case createReminder(CreateReminderInput)
    case completeReminder(CompleteReminderInput)
    case createAlarm(CreateAlarmInput)
    case updateAlarm(UpdateAlarmInput)
    case cancelAlarm(CancelAlarmInput)
    case scheduleNotification(ScheduleNotificationInput)
    case storeMemory(StoreMemoryInput)
    case updateMemory(UpdateMemoryInput)
    case createTask(CreateTaskInput)
    case completeTask(CompleteTaskInput)
    case createFollowUp(CreateFollowUpInput)
    case getUpcomingSchedule(GetUpcomingScheduleInput)

    public var kind: ToolKind {
        switch self {
        case .createCalendarEvent: return .createCalendarEvent
        case .updateCalendarEvent: return .updateCalendarEvent
        case .deleteCalendarEvent: return .deleteCalendarEvent
        case .createReminder: return .createReminder
        case .completeReminder: return .completeReminder
        case .createAlarm: return .createAlarm
        case .updateAlarm: return .updateAlarm
        case .cancelAlarm: return .cancelAlarm
        case .scheduleNotification: return .scheduleNotification
        case .storeMemory: return .storeMemory
        case .updateMemory: return .updateMemory
        case .createTask: return .createTask
        case .completeTask: return .completeTask
        case .createFollowUp: return .createFollowUp
        case .getUpcomingSchedule: return .getUpcomingSchedule
        }
    }

    /// A short line describing the request, for plan previews and the harness.
    public var summary: String {
        switch self {
        case .createCalendarEvent(let input):
            return "Calendar event \"\(input.title)\" at \(Self.format(input.start))"
        case .updateCalendarEvent(let input):
            return "Update calendar event \(input.eventID)"
        case .deleteCalendarEvent(let input):
            return "Delete calendar event \(input.eventID)"
        case .createReminder(let input):
            return "Reminder \"\(input.title)\""
        case .completeReminder(let input):
            return "Complete reminder \(input.reminderID)"
        case .createAlarm(let input):
            return "Alarm \"\(input.label)\" at \(Self.format(input.fireDate))"
        case .updateAlarm(let input):
            return "Update alarm \(input.alarmID)"
        case .cancelAlarm(let input):
            return "Cancel alarm \(input.alarmID)"
        case .scheduleNotification(let input):
            return "Notification \"\(input.title)\" at \(Self.format(input.fireDate))"
        case .storeMemory(let input):
            return "Remember (\(input.kind.rawValue)): \(input.content)"
        case .updateMemory(let input):
            return "Update memory \(input.memoryID)"
        case .createTask(let input):
            return "Task \"\(input.title)\""
        case .completeTask(let input):
            return "Complete task \(input.taskID)"
        case .createFollowUp(let input):
            return "Follow up on \(input.taskID) at \(Self.format(input.checkBackAt))"
        case .getUpcomingSchedule:
            return "Read upcoming schedule"
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
