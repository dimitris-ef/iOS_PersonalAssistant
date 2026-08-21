import AssistantDomain
import Foundation

public enum ToolDecodingError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownTool(name: String)
    case malformedArguments(kind: ToolKind, detail: String)
    case failedValidation(kind: ToolKind, detail: String)

    public var description: String {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool \"\(name)\""
        case .malformedArguments(let kind, let detail):
            return "Malformed arguments for \(kind.rawValue): \(detail)"
        case .failedValidation(let kind, let detail):
            return "Rejected \(kind.rawValue): \(detail)"
        }
    }
}

/// A model-proposed call that did not survive decoding or validation.
public struct RejectedToolCall: Hashable, Sendable {
    public var callID: ToolCallID
    public var name: String
    public var error: ToolDecodingError

    public init(callID: ToolCallID, name: String, error: ToolDecodingError) {
        self.callID = callID
        self.name = name
        self.error = error
    }
}

public struct DecodedToolCall: Hashable, Sendable {
    public var callID: ToolCallID
    public var request: ToolRequest

    public init(callID: ToolCallID, request: ToolRequest) {
        self.callID = callID
        self.request = request
    }
}

public struct ToolDecodingOutcome: Hashable, Sendable {
    public var accepted: [DecodedToolCall]
    public var rejected: [RejectedToolCall]

    public init(accepted: [DecodedToolCall] = [], rejected: [RejectedToolCall] = []) {
        self.accepted = accepted
        self.rejected = rejected
    }
}

/// Turns untyped tool calls from a model into typed, sanity-checked requests.
///
/// Anything unrecognised or malformed is rejected rather than guessed at — the
/// application's behaviour must never depend on interpreting model prose or
/// on partially understood arguments.
public struct ToolRequestDecoder: Sendable {
    private let dateProvider: any DateProvider

    public init(dateProvider: any DateProvider = SystemDateProvider()) {
        self.dateProvider = dateProvider
    }

    public func decode(_ calls: [AIToolCallEnvelope]) -> ToolDecodingOutcome {
        var outcome = ToolDecodingOutcome()
        for call in calls {
            do {
                let request = try decode(name: call.name, arguments: call.arguments)
                outcome.accepted.append(DecodedToolCall(callID: call.id, request: request))
            } catch let error as ToolDecodingError {
                outcome.rejected.append(
                    RejectedToolCall(callID: call.id, name: call.name, error: error)
                )
            } catch {
                outcome.rejected.append(
                    RejectedToolCall(
                        callID: call.id,
                        name: call.name,
                        error: .malformedArguments(
                            kind: ToolKind(rawValue: call.name) ?? .getUpcomingSchedule,
                            detail: String(describing: error)
                        )
                    )
                )
            }
        }
        return outcome
    }

    public func decode(name: String, arguments: JSONValue) throws -> ToolRequest {
        guard let kind = ToolKind(rawValue: name) else {
            throw ToolDecodingError.unknownTool(name: name)
        }

        let request = try decodeInput(kind: kind, arguments: arguments)
        try validate(request)
        return request
    }

    private func decodeInput(kind: ToolKind, arguments: JSONValue) throws -> ToolRequest {
        func input<T: Decodable>(_ type: T.Type) throws -> T {
            do {
                return try arguments.decode(as: T.self)
            } catch {
                throw ToolDecodingError.malformedArguments(
                    kind: kind,
                    detail: String(describing: error)
                )
            }
        }

        switch kind {
        case .createCalendarEvent:
            return .createCalendarEvent(try input(CreateCalendarEventInput.self))
        case .updateCalendarEvent:
            return .updateCalendarEvent(try input(UpdateCalendarEventInput.self))
        case .deleteCalendarEvent:
            return .deleteCalendarEvent(try input(DeleteCalendarEventInput.self))
        case .createReminder:
            return .createReminder(try input(CreateReminderInput.self))
        case .completeReminder:
            return .completeReminder(try input(CompleteReminderInput.self))
        case .createAlarm:
            return .createAlarm(try input(CreateAlarmInput.self))
        case .updateAlarm:
            return .updateAlarm(try input(UpdateAlarmInput.self))
        case .cancelAlarm:
            return .cancelAlarm(try input(CancelAlarmInput.self))
        case .scheduleNotification:
            return .scheduleNotification(try input(ScheduleNotificationInput.self))
        case .storeMemory:
            return .storeMemory(try input(StoreMemoryInput.self))
        case .updateMemory:
            return .updateMemory(try input(UpdateMemoryInput.self))
        case .createTask:
            return .createTask(try input(CreateTaskInput.self))
        case .completeTask:
            return .completeTask(try input(CompleteTaskInput.self))
        case .createFollowUp:
            return .createFollowUp(try input(CreateFollowUpInput.self))
        case .getUpcomingSchedule:
            return .getUpcomingSchedule(try input(GetUpcomingScheduleInput.self))
        case .createRoutine:
            return .createRoutine(try input(CreateRoutineInput.self))
        case .addTaskDependency:
            return .addTaskDependency(try input(AddTaskDependencyInput.self))
        case .startTask:
            return .startTask(try input(StartTaskInput.self))
        case .askClarification:
            return .askClarification(try input(AskClarificationInput.self))
        }
    }

    /// Cross-field checks that a schema cannot express.
    private func validate(_ request: ToolRequest) throws {
        switch request {
        case .createCalendarEvent(let input):
            try requireNonEmpty(input.title, field: "title", kind: request.kind)
            if let end = input.end, end < input.start {
                throw ToolDecodingError.failedValidation(
                    kind: request.kind,
                    detail: "end is before start"
                )
            }

        case .createAlarm(let input):
            try requireNonEmpty(input.label, field: "label", kind: request.kind)
            try requireFuture(input.fireDate, field: "fireDate", kind: request.kind)

        case .scheduleNotification(let input):
            try requireNonEmpty(input.title, field: "title", kind: request.kind)
            try requireFuture(input.fireDate, field: "fireDate", kind: request.kind)

        case .createReminder(let input):
            try requireNonEmpty(input.title, field: "title", kind: request.kind)

        case .createTask(let input):
            try requireNonEmpty(input.title, field: "title", kind: request.kind)
            try requireSaneDuration(input.estimatedMinutes, field: "estimatedMinutes", kind: request.kind)
            try requireSaneSteps(input.preparationSteps, kind: request.kind)

        case .createRoutine(let input):
            try requireNonEmpty(input.title, field: "title", kind: request.kind)
            // The rule itself. This is where "every 0 days", "weekly on no
            // days", "the 45th of the month" and "ends before it starts" are
            // refused — section 55, before anything can be persisted and long
            // before an occurrence generator would have to cope with it.
            do {
                _ = try input.recurrence.resolvedRule(now: dateProvider.now)
            } catch {
                throw ToolDecodingError.failedValidation(
                    kind: request.kind,
                    detail: String(describing: error)
                )
            }
            try requireSaneSteps(input.preparationSteps, kind: request.kind)
            try requireSaneDuration(
                input.preparationDurationMinutes,
                field: "preparationDurationMinutes",
                kind: request.kind
            )
            try requireSaneDuration(
                input.travelDurationMinutes,
                field: "travelDurationMinutes",
                kind: request.kind
            )
            if let window = input.recoveryWindowMinutes, window < 0 {
                throw ToolDecodingError.failedValidation(
                    kind: request.kind,
                    detail: "recoveryWindowMinutes is negative"
                )
            }

        case .addTaskDependency(let input):
            // A task cannot wait for itself. Longer cycles need every task to
            // check against, so they are caught at execution — but this one is
            // decidable here, and catching it here means the model gets told
            // immediately rather than after authorization.
            if input.prerequisiteTaskID == input.dependentTaskID {
                throw ToolDecodingError.failedValidation(
                    kind: request.kind,
                    detail: "a task cannot depend on itself"
                )
            }

        case .storeMemory(let input):
            try requireNonEmpty(input.content, field: "content", kind: request.kind)

        case .createFollowUp(let input):
            try requireFuture(input.checkBackAt, field: "checkBackAt", kind: request.kind)

        case .askClarification(let input):
            // An empty question would stall the turn with nothing on screen for
            // the user to answer.
            try requireNonEmpty(input.question, field: "question", kind: request.kind)

        case .updateCalendarEvent, .deleteCalendarEvent, .completeReminder,
             .updateAlarm, .cancelAlarm, .updateMemory, .completeTask,
             .getUpcomingSchedule, .startTask:
            break
        }
    }

    private func requireNonEmpty(_ value: String, field: String, kind: ToolKind) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolDecodingError.failedValidation(kind: kind, detail: "\(field) is empty")
        }
    }

    /// Section 57: absurd durations, refused rather than clamped.
    ///
    /// Clamping would be friendlier and worse. A model that says a shower takes
    /// six hours has misunderstood something, and silently rewriting it to two
    /// leaves the user with a plan nobody agreed to; a rejection gets corrected
    /// on the next round of the loop.
    private func requireSaneDuration(_ minutes: Int?, field: String, kind: ToolKind) throws {
        guard let minutes else { return }
        if minutes < 0 {
            throw ToolDecodingError.failedValidation(kind: kind, detail: "\(field) is negative")
        }
        if minutes > 12 * 60 {
            throw ToolDecodingError.failedValidation(
                kind: kind,
                detail: "\(field) of \(minutes) minutes is implausible"
            )
        }
    }

    private func requireSaneSteps(_ steps: [PreparationStepInput]?, kind: ToolKind) throws {
        guard let steps else { return }
        if steps.count > 8 {
            throw ToolDecodingError.failedValidation(
                kind: kind,
                detail: "too many preparation steps (\(steps.count))"
            )
        }
        for step in steps {
            try requireNonEmpty(step.title, field: "preparation step title", kind: kind)
            if let minutes = step.estimatedMinutes {
                if minutes < 0 {
                    throw ToolDecodingError.failedValidation(
                        kind: kind,
                        detail: "preparation step duration is negative"
                    )
                }
                if TimeSpan.minutes(Double(minutes)) > PreparationStepInput.maximumDuration {
                    throw ToolDecodingError.failedValidation(
                        kind: kind,
                        detail: "preparation step \"\(step.title)\" claims \(minutes) minutes"
                    )
                }
            }
            if let necessity = step.necessity,
               StepNecessity(rawValue: necessity.lowercased()) == nil {
                throw ToolDecodingError.failedValidation(
                    kind: kind,
                    detail: "\"\(necessity)\" is not a step necessity"
                )
            }
        }
    }

    private func requireFuture(_ date: Date, field: String, kind: ToolKind) throws {
        // A small grace period: a model may compute a fire date a moment before
        // we get around to validating it.
        if date < dateProvider.now.addingTimeInterval(-TimeSpan.minutes(1)) {
            throw ToolDecodingError.failedValidation(kind: kind, detail: "\(field) is in the past")
        }
    }
}

/// The decoder's view of a proposed tool call.
///
/// `AssistantTools` deliberately does not import the AI module — the engine
/// adapts `AIToolCall` into this on the way in, which keeps the tool system
/// usable independently of how a call was produced (model, UI, App Intent).
public struct AIToolCallEnvelope: Hashable, Sendable {
    public var id: ToolCallID
    public var name: String
    public var arguments: JSONValue

    public init(id: ToolCallID = ToolCallID(), name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
