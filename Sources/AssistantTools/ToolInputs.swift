import AssistantDomain
import Foundation

// Typed inputs for every tool the model may request.
//
// These are the only shapes that cross the boundary from a model into the
// application. Each one is `Codable` so a provider's untyped JSON arguments can
// be decoded exactly once, and `Hashable` so plans can be compared in tests.

public struct CreateCalendarEventInput: Hashable, Codable, Sendable {
    /// Assigned by the action planner, not by the model, so that reminder
    /// stages generated alongside the event can reference it before it exists.
    /// Absent from the published schema; models should never set it.
    public var eventID: CalendarItem.ID?
    public var title: String
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool?
    public var location: String?
    public var notes: String?
    public var importance: Importance?
    public var travelDurationMinutes: Int?
    public var preparationDurationMinutes: Int?
    /// Whether the assistant should build a supporting reminder plan for this
    /// event. Defaults to true — the whole point of the product.
    public var wantsReminderSupport: Bool?

    public init(
        eventID: CalendarItem.ID? = nil,
        title: String,
        start: Date,
        end: Date? = nil,
        isAllDay: Bool? = nil,
        location: String? = nil,
        notes: String? = nil,
        importance: Importance? = nil,
        travelDurationMinutes: Int? = nil,
        preparationDurationMinutes: Int? = nil,
        wantsReminderSupport: Bool? = nil
    ) {
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.importance = importance
        self.travelDurationMinutes = travelDurationMinutes
        self.preparationDurationMinutes = preparationDurationMinutes
        self.wantsReminderSupport = wantsReminderSupport
    }
}

public struct UpdateCalendarEventInput: Hashable, Codable, Sendable {
    public var eventID: CalendarItem.ID
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var location: String?
    public var notes: String?

    public init(
        eventID: CalendarItem.ID,
        title: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
    }
}

public struct DeleteCalendarEventInput: Hashable, Codable, Sendable {
    public var eventID: CalendarItem.ID

    public init(eventID: CalendarItem.ID) {
        self.eventID = eventID
    }
}

public struct CreateReminderInput: Hashable, Codable, Sendable {
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var listName: String?
    public var relatedTaskID: TaskItem.ID?

    public init(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        listName: String? = nil,
        relatedTaskID: TaskItem.ID? = nil
    ) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.listName = listName
        self.relatedTaskID = relatedTaskID
    }
}

public struct CompleteReminderInput: Hashable, Codable, Sendable {
    public var reminderID: ReminderItem.ID

    public init(reminderID: ReminderItem.ID) {
        self.reminderID = reminderID
    }
}

public struct CreateAlarmInput: Hashable, Codable, Sendable {
    public var label: String
    public var fireDate: Date
    public var allowsSnooze: Bool?
    public var snoozeMinutes: Int?
    public var maximumSnoozes: Int?

    public init(
        label: String,
        fireDate: Date,
        allowsSnooze: Bool? = nil,
        snoozeMinutes: Int? = nil,
        maximumSnoozes: Int? = nil
    ) {
        self.label = label
        self.fireDate = fireDate
        self.allowsSnooze = allowsSnooze
        self.snoozeMinutes = snoozeMinutes
        self.maximumSnoozes = maximumSnoozes
    }
}

public struct UpdateAlarmInput: Hashable, Codable, Sendable {
    public var alarmID: AlarmRequest.ID
    public var label: String?
    public var fireDate: Date?
    public var allowsSnooze: Bool?

    public init(
        alarmID: AlarmRequest.ID,
        label: String? = nil,
        fireDate: Date? = nil,
        allowsSnooze: Bool? = nil
    ) {
        self.alarmID = alarmID
        self.label = label
        self.fireDate = fireDate
        self.allowsSnooze = allowsSnooze
    }
}

public struct CancelAlarmInput: Hashable, Codable, Sendable {
    public var alarmID: AlarmRequest.ID

    public init(alarmID: AlarmRequest.ID) {
        self.alarmID = alarmID
    }
}

public struct ScheduleNotificationInput: Hashable, Codable, Sendable {
    public var title: String
    public var body: String
    public var fireDate: Date
    public var escalation: EscalationLevel?
    public var requiresCompletionConfirmation: Bool?
    public var relatedTaskID: TaskItem.ID?
    public var stageID: ReminderStage.ID?

    public init(
        title: String,
        body: String,
        fireDate: Date,
        escalation: EscalationLevel? = nil,
        requiresCompletionConfirmation: Bool? = nil,
        relatedTaskID: TaskItem.ID? = nil,
        stageID: ReminderStage.ID? = nil
    ) {
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.escalation = escalation
        self.requiresCompletionConfirmation = requiresCompletionConfirmation
        self.relatedTaskID = relatedTaskID
        self.stageID = stageID
    }
}

public struct StoreMemoryInput: Hashable, Codable, Sendable {
    public var content: String
    public var kind: MemoryKind
    public var tags: [String]?
    public var salience: Double?

    public init(content: String, kind: MemoryKind, tags: [String]? = nil, salience: Double? = nil) {
        self.content = content
        self.kind = kind
        self.tags = tags
        self.salience = salience
    }
}

public struct UpdateMemoryInput: Hashable, Codable, Sendable {
    public var memoryID: MemoryItem.ID
    public var content: String?
    public var kind: MemoryKind?
    public var tags: [String]?
    public var salience: Double?

    public init(
        memoryID: MemoryItem.ID,
        content: String? = nil,
        kind: MemoryKind? = nil,
        tags: [String]? = nil,
        salience: Double? = nil
    ) {
        self.memoryID = memoryID
        self.content = content
        self.kind = kind
        self.tags = tags
        self.salience = salience
    }
}

public struct CreateTaskInput: Hashable, Codable, Sendable {
    /// Assigned by the action planner, not by the model. See
    /// ``CreateCalendarEventInput/eventID``.
    public var taskID: TaskItem.ID?
    public var title: String
    public var details: String?
    public var importance: Importance?
    public var dueDate: Date?
    public var fixedDate: Date?
    public var flexibleWindow: TimeWindow?
    public var preparationDurationMinutes: Int?
    public var travelDurationMinutes: Int?
    public var wantsReminderSupport: Bool?

    public init(
        taskID: TaskItem.ID? = nil,
        title: String,
        details: String? = nil,
        importance: Importance? = nil,
        dueDate: Date? = nil,
        fixedDate: Date? = nil,
        flexibleWindow: TimeWindow? = nil,
        preparationDurationMinutes: Int? = nil,
        travelDurationMinutes: Int? = nil,
        wantsReminderSupport: Bool? = nil
    ) {
        self.taskID = taskID
        self.title = title
        self.details = details
        self.importance = importance
        self.dueDate = dueDate
        self.fixedDate = fixedDate
        self.flexibleWindow = flexibleWindow
        self.preparationDurationMinutes = preparationDurationMinutes
        self.travelDurationMinutes = travelDurationMinutes
        self.wantsReminderSupport = wantsReminderSupport
    }
}

public struct CompleteTaskInput: Hashable, Codable, Sendable {
    public var taskID: TaskItem.ID
    /// Explicit confirmation from the user, as opposed to an inferred completion.
    public var confirmedByUser: Bool?

    public init(taskID: TaskItem.ID, confirmedByUser: Bool? = nil) {
        self.taskID = taskID
        self.confirmedByUser = confirmedByUser
    }
}

public struct CreateFollowUpInput: Hashable, Codable, Sendable {
    public var taskID: TaskItem.ID
    public var checkBackAt: Date
    public var message: String?
    public var escalation: EscalationLevel?

    public init(
        taskID: TaskItem.ID,
        checkBackAt: Date,
        message: String? = nil,
        escalation: EscalationLevel? = nil
    ) {
        self.taskID = taskID
        self.checkBackAt = checkBackAt
        self.message = message
        self.escalation = escalation
    }
}

public struct GetUpcomingScheduleInput: Hashable, Codable, Sendable {
    public var window: TimeWindow?
    public var limit: Int?

    public init(window: TimeWindow? = nil, limit: Int? = nil) {
        self.window = window
        self.limit = limit
    }
}

/// One focused question, asked because guessing would be worse.
///
/// `options` is what makes this useful rather than annoying: "which appointment
/// do you mean" with the two candidates listed is answerable in a word, and it
/// keeps the assistant from modifying an arbitrary event when two of them match.
public struct AskClarificationInput: Hashable, Codable, Sendable {
    public var question: String
    /// The choices, when there is a small closed set of them.
    public var options: [String]?

    public init(question: String, options: [String]? = nil) {
        self.question = question
        self.options = options
    }
}
