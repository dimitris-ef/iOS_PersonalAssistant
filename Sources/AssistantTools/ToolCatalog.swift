import AssistantDomain
import Foundation

/// The declaration of a single tool: its name, what it is for, and the exact
/// shape of its arguments.
public struct ToolSpecification: Hashable, Sendable {
    public var kind: ToolKind
    public var summary: String
    public var parameters: JSONSchema

    public init(kind: ToolKind, summary: String, parameters: JSONSchema) {
        self.kind = kind
        self.summary = summary
        self.parameters = parameters
    }

    /// The wire name a model uses to call this tool.
    public var name: String { kind.rawValue }
}

/// The full set of tools the assistant exposes.
///
/// The catalogue belongs to the application, not to any provider: switching
/// models does not change which tools exist or what they mean.
public enum ToolCatalog {
    public static let all: [ToolSpecification] = ToolKind.allCases.map(specification(for:))

    public static func specification(for kind: ToolKind) -> ToolSpecification {
        switch kind {
        case .createCalendarEvent:
            return ToolSpecification(
                kind: kind,
                summary: "Add an event to the user's calendar.",
                parameters: .object(
                    properties: [
                        "title": .string(description: "Short name of the event."),
                        "start": .string(description: "Start time.", format: .dateTime),
                        "end": .string(description: "End time. Defaults to one hour after start.", format: .dateTime),
                        "isAllDay": .boolean(description: "True for all-day events."),
                        "location": .string(description: "Where the event happens."),
                        "notes": .string(),
                        "importance": .enumeration(values: importanceValues, description: "How important this is."),
                        "travelDurationMinutes": .integer(description: "Minutes needed to travel there."),
                        "preparationDurationMinutes": .integer(description: "Minutes needed to get ready."),
                        "wantsReminderSupport": .boolean(
                            description: "Whether the assistant should build a staged reminder plan. Defaults to true."
                        ),
                    ],
                    required: ["title", "start"]
                )
            )

        case .updateCalendarEvent:
            return ToolSpecification(
                kind: kind,
                summary: "Change an existing calendar event.",
                parameters: .object(
                    properties: [
                        "eventID": .string(description: "Identifier of the event.", format: .uuid),
                        "title": .string(),
                        "start": .string(format: .dateTime),
                        "end": .string(format: .dateTime),
                        "location": .string(),
                        "notes": .string(),
                    ],
                    required: ["eventID"]
                )
            )

        case .deleteCalendarEvent:
            return ToolSpecification(
                kind: kind,
                summary: "Remove a calendar event.",
                parameters: .object(
                    properties: ["eventID": .string(format: .uuid)],
                    required: ["eventID"]
                )
            )

        case .createReminder:
            return ToolSpecification(
                kind: kind,
                summary: "Add an entry to the system reminders list.",
                parameters: .object(
                    properties: [
                        "title": .string(),
                        "notes": .string(),
                        "dueDate": .string(format: .dateTime),
                        "listName": .string(),
                        "relatedTaskID": .string(format: .uuid),
                    ],
                    required: ["title"]
                )
            )

        case .completeReminder:
            return ToolSpecification(
                kind: kind,
                summary: "Mark a reminders-list entry as done.",
                parameters: .object(
                    properties: ["reminderID": .string(format: .uuid)],
                    required: ["reminderID"]
                )
            )

        case .createAlarm:
            return ToolSpecification(
                kind: kind,
                summary: "Set an alarm that sounds and must be dismissed.",
                parameters: .object(
                    properties: [
                        "label": .string(),
                        "fireDate": .string(format: .dateTime),
                        "allowsSnooze": .boolean(),
                        "snoozeMinutes": .integer(),
                        "maximumSnoozes": .integer(),
                    ],
                    required: ["label", "fireDate"]
                )
            )

        case .updateAlarm:
            return ToolSpecification(
                kind: kind,
                summary: "Change an existing alarm.",
                parameters: .object(
                    properties: [
                        "alarmID": .string(format: .uuid),
                        "label": .string(),
                        "fireDate": .string(format: .dateTime),
                        "allowsSnooze": .boolean(),
                    ],
                    required: ["alarmID"]
                )
            )

        case .cancelAlarm:
            return ToolSpecification(
                kind: kind,
                summary: "Cancel an alarm.",
                parameters: .object(
                    properties: ["alarmID": .string(format: .uuid)],
                    required: ["alarmID"]
                )
            )

        case .scheduleNotification:
            return ToolSpecification(
                kind: kind,
                summary: "Schedule a notification at a specific time.",
                parameters: .object(
                    properties: [
                        "title": .string(),
                        "body": .string(),
                        "fireDate": .string(format: .dateTime),
                        "escalation": .enumeration(
                            values: escalationValues,
                            description: "How insistent the notification should be."
                        ),
                        "requiresCompletionConfirmation": .boolean(
                            description: "If true, dismissing it does not mark the task done."
                        ),
                        "relatedTaskID": .string(format: .uuid),
                        "stageID": .string(format: .uuid),
                    ],
                    required: ["title", "body", "fireDate"]
                )
            )

        case .storeMemory:
            return ToolSpecification(
                kind: kind,
                summary: "Remember something about the user long-term.",
                parameters: .object(
                    properties: [
                        "content": .string(description: "The fact, written in the third person."),
                        "kind": .enumeration(values: memoryKindValues),
                        "tags": .array(items: .string()),
                        "salience": .number(description: "0 to 1; how important this is to recall."),
                    ],
                    required: ["content", "kind"]
                )
            )

        case .updateMemory:
            return ToolSpecification(
                kind: kind,
                summary: "Revise something previously remembered.",
                parameters: .object(
                    properties: [
                        "memoryID": .string(format: .uuid),
                        "content": .string(),
                        "kind": .enumeration(values: memoryKindValues),
                        "tags": .array(items: .string()),
                        "salience": .number(),
                    ],
                    required: ["memoryID"]
                )
            )

        case .createTask:
            return ToolSpecification(
                kind: kind,
                summary: "Track something the user needs to do.",
                parameters: .object(
                    properties: [
                        "title": .string(),
                        "details": .string(),
                        "importance": .enumeration(values: importanceValues),
                        "dueDate": .string(description: "Hard deadline.", format: .dateTime),
                        "fixedDate": .string(description: "Use when the task happens at a set time.", format: .dateTime),
                        "flexibleWindow": .object(
                            properties: [
                                "start": .string(format: .dateTime),
                                "end": .string(format: .dateTime),
                            ],
                            required: ["start", "end"],
                            description: "Use for \"sometime this week\" style work."
                        ),
                        "preparationDurationMinutes": .integer(),
                        "travelDurationMinutes": .integer(),
                        "wantsReminderSupport": .boolean(),
                    ],
                    required: ["title"]
                )
            )

        case .completeTask:
            return ToolSpecification(
                kind: kind,
                summary: "Mark a task complete. Only use when the user actually confirmed it.",
                parameters: .object(
                    properties: [
                        "taskID": .string(format: .uuid),
                        "confirmedByUser": .boolean(
                            description: "True only when the user explicitly said it is done."
                        ),
                    ],
                    required: ["taskID"]
                )
            )

        case .createFollowUp:
            return ToolSpecification(
                kind: kind,
                summary: "Check back on a task that was not confirmed complete.",
                parameters: .object(
                    properties: [
                        "taskID": .string(format: .uuid),
                        "checkBackAt": .string(format: .dateTime),
                        "message": .string(),
                        "escalation": .enumeration(values: escalationValues),
                    ],
                    required: ["taskID", "checkBackAt"]
                )
            )

        case .getUpcomingSchedule:
            return ToolSpecification(
                kind: kind,
                summary: "Read what is coming up. Read-only.",
                parameters: .object(
                    properties: [
                        "window": .object(
                            properties: [
                                "start": .string(format: .dateTime),
                                "end": .string(format: .dateTime),
                            ],
                            required: ["start", "end"]
                        ),
                        "limit": .integer(),
                    ],
                    required: []
                )
            )

        case .askClarification:
            return ToolSpecification(
                kind: kind,
                // The wording is doing real work. Left to itself a model asks
                // for confirmation constantly — "how long before?", "should I
                // remind you?" — for things the app already has a policy about,
                // and every one of those questions is a step someone with a
                // depleted executive function has to climb. The description
                // therefore names the one case that justifies asking: two or
                // more real candidates and no way to choose.
                summary: """
                    Ask the user one question, and only when acting would \
                    otherwise be materially ambiguous — for example when several \
                    existing events or tasks match what they said and picking \
                    the wrong one would change or delete the wrong thing. Do not \
                    use it for anything the app already decides: reminder \
                    timing, how far in advance to warn, escalation or follow-up \
                    all have defaults. When you call this, nothing else you \
                    proposed in the same turn will be carried out.
                    """,
                parameters: .object(
                    properties: [
                        "question": .string(description: "One short question, in the second person."),
                        "options": .array(
                            items: .string(),
                            description: "The candidates to choose between, when there is a small set."
                        ),
                    ],
                    required: ["question"]
                )
            )
        }
    }

    // Derived from the enums themselves so the published schema cannot drift
    // away from what the decoder will actually accept.
    private static let importanceValues = Importance.allCases.map(\.rawValue)
    private static let escalationValues = EscalationLevel.allCases.map(\.rawValue)
    private static let memoryKindValues = MemoryKind.allCases.map(\.rawValue)
}
