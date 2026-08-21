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
    /// Roughly how long the work itself takes, once started.
    public var estimatedMinutes: Int?
    /// The ordered things to do before this can happen.
    public var preparationSteps: [PreparationStepInput]?

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
        wantsReminderSupport: Bool? = nil,
        estimatedMinutes: Int? = nil,
        preparationSteps: [PreparationStepInput]? = nil
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
        self.estimatedMinutes = estimatedMinutes
        self.preparationSteps = preparationSteps
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

// MARK: - Part 8: recurrence, dependencies and start support

/// A recurrence rule as a model may express it.
///
/// Deliberately flat and stringly-typed at the edges — `frequency` is a string,
/// `time` is "HH:mm" — because that is what survives a JSON schema round trip
/// through any provider. It becomes a validated ``RecurrenceRule`` in the
/// decoder, which is where impossible rules are rejected.
public struct RecurrenceInput: Hashable, Codable, Sendable {
    /// `daily`, `weekly` or `monthly`.
    public var frequency: String
    /// Every *n* days, weeks or months. Defaults to 1.
    public var interval: Int?
    /// 1 = Sunday … 7 = Saturday. Required for a weekly rule.
    public var weekdays: [Int]?
    public var dayOfMonth: Int?
    /// "HH:mm", 24-hour.
    public var time: String
    /// When the rule starts applying. Defaults to now.
    public var startDate: Date?
    public var endDate: Date?

    public init(
        frequency: String,
        interval: Int? = nil,
        weekdays: [Int]? = nil,
        dayOfMonth: Int? = nil,
        time: String,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
        self.time = time
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// One preparation step, as proposed.
public struct PreparationStepInput: Hashable, Codable, Sendable {
    public var title: String
    public var estimatedMinutes: Int?
    /// `required`, `recommended` or `optional`. Defaults to required.
    public var necessity: String?

    public init(title: String, estimatedMinutes: Int? = nil, necessity: String? = nil) {
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.necessity = necessity
    }
}

public struct CreateRoutineInput: Hashable, Codable, Sendable {
    /// Assigned by the planner, not by the model.
    public var routineID: Routine.ID?
    public var title: String
    public var details: String?
    public var importance: Importance?
    public var recurrence: RecurrenceInput
    /// How long after the scheduled time a missed occurrence is still worth
    /// doing. Zero means it never is.
    public var recoveryWindowMinutes: Int?
    /// Whether a missed evening occurrence stays useful the next morning.
    public var recoveryAllowsNextDay: Bool?
    public var preparationDurationMinutes: Int?
    public var travelDurationMinutes: Int?
    public var preparationSteps: [PreparationStepInput]?

    public init(
        routineID: Routine.ID? = nil,
        title: String,
        details: String? = nil,
        importance: Importance? = nil,
        recurrence: RecurrenceInput,
        recoveryWindowMinutes: Int? = nil,
        recoveryAllowsNextDay: Bool? = nil,
        preparationDurationMinutes: Int? = nil,
        travelDurationMinutes: Int? = nil,
        preparationSteps: [PreparationStepInput]? = nil
    ) {
        self.routineID = routineID
        self.title = title
        self.details = details
        self.importance = importance
        self.recurrence = recurrence
        self.recoveryWindowMinutes = recoveryWindowMinutes
        self.recoveryAllowsNextDay = recoveryAllowsNextDay
        self.preparationDurationMinutes = preparationDurationMinutes
        self.travelDurationMinutes = travelDurationMinutes
        self.preparationSteps = preparationSteps
    }
}

public struct AddTaskDependencyInput: Hashable, Codable, Sendable {
    /// The task that must happen first.
    public var prerequisiteTaskID: TaskItem.ID
    /// The task that has to wait.
    public var dependentTaskID: TaskItem.ID

    public init(prerequisiteTaskID: TaskItem.ID, dependentTaskID: TaskItem.ID) {
        self.prerequisiteTaskID = prerequisiteTaskID
        self.dependentTaskID = dependentTaskID
    }
}

public struct StartTaskInput: Hashable, Codable, Sendable {
    public var taskID: TaskItem.ID

    public init(taskID: TaskItem.ID) {
        self.taskID = taskID
    }
}

// MARK: - Turning proposals into domain values

/// Why a proposed recurrence could not become a rule at all.
///
/// Separate from ``RecurrenceRule/ValidationError``, which is about rules that
/// are well-formed but describe nothing. These two are about arguments that are
/// not a rule yet: a frequency nobody has heard of, a time that is not a time.
public enum RecurrenceInputError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownFrequency(String)
    case malformedTime(String)

    public var description: String {
        switch self {
        case .unknownFrequency(let value):
            let known = RecurrenceRule.Frequency.allCases.map(\.rawValue).joined(separator: ", ")
            return "\"\(value)\" is not a recurrence frequency; expected one of \(known)"
        case .malformedTime(let value):
            return "\"\(value)\" is not a time of day; expected HH:mm"
        }
    }
}

extension RecurrenceInput {
    /// The validated rule this input describes.
    ///
    /// Throws twice over on purpose: once for arguments that are not a rule
    /// (``RecurrenceInputError``) and once for rules that cannot happen
    /// (``RecurrenceRule/ValidationError``). Section 55 asks for both, and a
    /// caller that wants to report the difference to the user can.
    public func resolvedRule(now: Date) throws -> RecurrenceRule {
        guard let frequency = RecurrenceRule.Frequency(rawValue: frequency.lowercased()) else {
            throw RecurrenceInputError.unknownFrequency(frequency)
        }
        guard let timeOfDay = Self.parseTime(time) else {
            throw RecurrenceInputError.malformedTime(time)
        }

        let rule = RecurrenceRule(
            frequency: frequency,
            interval: interval ?? 1,
            weekdays: weekdays ?? [],
            dayOfMonth: dayOfMonth,
            timeOfDay: timeOfDay,
            startDate: startDate ?? now,
            endDate: endDate
        )
        try rule.validate()
        return rule
    }

    /// "HH:mm", strictly. Nothing clever: a model that writes "9am" gets a
    /// rejection it can correct, not a guess that silently means 09:00 in one
    /// locale and something else in another.
    static func parseTime(_ text: String) -> TimeOfDay? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return TimeOfDay(hour: hour, minute: minute)
    }
}

extension PreparationStepInput {
    /// The longest a single step may claim to take.
    ///
    /// Section 57. A step is a thing you do before the thing; four hours of
    /// "get ready" is not a step, it is a plan that would wreck every start
    /// time computed from it.
    public static let maximumDuration = TimeSpan.hours(2)

    /// The structured step, bounded.
    ///
    /// `parent` is whatever the step hangs off — a task or a routine id — so
    /// the identity is stable across replanning without colliding between two
    /// tasks that both start with "Find your keys".
    public func resolvedStep(parent: String, sequence: Int) -> PreparationStep {
        let title = String(
            self.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        )
        let minutes = Double(max(0, estimatedMinutes ?? 5))
        return PreparationStep(
            id: PreparationStep.identity(parent: parent, title: title),
            title: title,
            estimatedDuration: min(TimeSpan.minutes(minutes), Self.maximumDuration),
            necessity: necessity.flatMap { StepNecessity(rawValue: $0.lowercased()) } ?? .required,
            sequence: sequence
        )
    }
}

extension Array where Element == PreparationStepInput {
    /// Structured steps in the order proposed, dropping the empty ones.
    ///
    /// Bounded at eight, the same ceiling the start-support service applies to
    /// a decomposition: a list longer than that is not a preparation sequence,
    /// and someone who needs help starting is the last person who should be
    /// handed twenty checkboxes.
    public func resolvedSteps(parent: String) -> [PreparationStep] {
        prefix(8)
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated()
            .map { index, input in input.resolvedStep(parent: parent, sequence: index) }
    }
}
