import AssistantDomain
import AssistantTools
import ExecutiveSupport
import Foundation

/// The result of planning: the actions to run, plus any reminder plans that
/// were generated along the way and need persisting.
public struct PlanningOutput: Sendable {
    public var plan: AssistantActionPlan
    public var reminderPlans: [ReminderPlan]

    public init(plan: AssistantActionPlan, reminderPlans: [ReminderPlan] = []) {
        self.plan = plan
        self.reminderPlans = reminderPlans
    }
}

/// Turns decoded tool calls into the plan the app will actually run.
public protocol ActionPlanner: Sendable {
    func makePlan(
        from decoded: ToolDecodingOutcome,
        context: AssistantContext
    ) -> PlanningOutput
}

/// The default planner.
///
/// Its one substantive job beyond authorization is **support expansion**: when
/// the model asks for a calendar event or a timed task, the planner asks the
/// ``SupportPlanner`` for a staged reminder plan and adds the resulting
/// notification actions itself. That is why "I have a haircut Sunday at 10 PM"
/// produces four or five actions from a single tool call, and why the reminder
/// strategy is a property of the application rather than of the model.
public struct DefaultActionPlanner: ActionPlanner {
    private let supportPlanner: any SupportPlanner
    private let authorizer: any ToolAuthorizing

    public init(
        supportPlanner: any SupportPlanner = DefaultSupportPlanner(),
        authorizer: any ToolAuthorizing = SettingsToolAuthorizer()
    ) {
        self.supportPlanner = supportPlanner
        self.authorizer = authorizer
    }

    public func makePlan(
        from decoded: ToolDecodingOutcome,
        context: AssistantContext
    ) -> PlanningOutput {
        var actions: [AssistantAction] = []
        var reminderPlans: [ReminderPlan] = []

        for call in decoded.accepted {
            let request = normalized(call.request)
            actions.append(
                AssistantAction(
                    request: request,
                    origin: .model,
                    authorization: authorizer.authorization(for: request, settings: context.settings),
                    sourceCallID: call.callID
                )
            )

            guard let subject = supportSubject(for: request, context: context) else { continue }

            let plan = supportPlanner.makePlan(
                for: subject,
                context: SupportPlanningContext(
                    profile: context.profile,
                    preferences: context.settings.support,
                    now: context.now,
                    calendar: context.calendar
                )
            )
            reminderPlans.append(plan)

            let resolver = ReminderScheduleResolver(calendar: context.calendar)
            let scheduled = resolver.resolve(
                plan: plan,
                now: context.now,
                quietHours: context.profile.quietHours
            )

            for reminder in scheduled {
                actions.append(
                    AssistantAction(
                        request: action(for: reminder, subject: subject),
                        origin: .supportPlanner,
                        authorization: context.settings.authorization(for: kind(for: reminder)),
                        rationale: "\(reminder.kind.rawValue) reminder for \(subject.title)"
                    )
                )
            }
        }

        return PlanningOutput(
            plan: AssistantActionPlan(
                actions: actions,
                rejected: decoded.rejected,
                createdAt: context.now
            ),
            reminderPlans: reminderPlans
        )
    }

    // MARK: Normalisation

    /// Fills in the identifiers the planner owns, so reminder stages can point
    /// at an entity that does not exist yet.
    private func normalized(_ request: ToolRequest) -> ToolRequest {
        switch request {
        case .createCalendarEvent(var input):
            if input.eventID == nil { input.eventID = CalendarItem.ID() }
            return .createCalendarEvent(input)
        case .createTask(var input):
            if input.taskID == nil { input.taskID = TaskItem.ID() }
            return .createTask(input)
        default:
            return request
        }
    }

    // MARK: Support expansion

    private func supportSubject(
        for request: ToolRequest,
        context: AssistantContext
    ) -> ReminderSubject? {
        switch request {
        case .createCalendarEvent(let input):
            guard input.wantsReminderSupport ?? true, let eventID = input.eventID else { return nil }
            return ReminderSubject(
                reference: .calendarItem(eventID),
                title: input.title,
                anchor: .moment(input.start),
                importance: input.importance ?? .normal,
                preparationDuration: minutes(input.preparationDurationMinutes)
                    ?? context.profile.defaultPreparationDuration,
                travelDuration: minutes(input.travelDurationMinutes)
                    ?? travelDuration(for: input.location, context: context),
                isTimeFixed: true
            )

        case .createTask(let input):
            guard input.wantsReminderSupport ?? true, let taskID = input.taskID else { return nil }
            guard let anchor = anchor(for: input) else { return nil }
            return ReminderSubject(
                reference: .task(taskID),
                title: input.title,
                anchor: anchor,
                importance: input.importance ?? .normal,
                preparationDuration: minutes(input.preparationDurationMinutes),
                travelDuration: minutes(input.travelDurationMinutes),
                isTimeFixed: input.fixedDate != nil
            )

        default:
            return nil
        }
    }

    private func anchor(for input: CreateTaskInput) -> ReminderAnchor? {
        if let fixed = input.fixedDate { return .moment(fixed) }
        if let window = input.flexibleWindow { return .window(window) }
        if let due = input.dueDate { return .deadline(due) }
        return nil
    }

    /// No route information yet, so a location means "some travel is needed"
    /// and we fall back to the user's stated default.
    private func travelDuration(for location: String?, context: AssistantContext) -> TimeInterval? {
        guard let location, !location.isEmpty else { return nil }
        return context.profile.defaultTravelDuration
    }

    private func minutes(_ value: Int?) -> TimeInterval? {
        value.map { TimeSpan.minutes(Double($0)) }
    }

    private func kind(for reminder: ScheduledReminder) -> ToolKind {
        switch reminder.channel {
        case .alarm: return .createAlarm
        case .notification: return .scheduleNotification
        case .reminderList: return .createReminder
        }
    }

    private func action(for reminder: ScheduledReminder, subject: ReminderSubject) -> ToolRequest {
        switch reminder.channel {
        case .alarm:
            return .createAlarm(
                CreateAlarmInput(
                    label: reminder.body,
                    fireDate: reminder.fireDate
                )
            )
        case .reminderList:
            return .createReminder(
                CreateReminderInput(
                    title: reminder.title,
                    notes: reminder.body,
                    dueDate: reminder.fireDate,
                    relatedTaskID: relatedTaskID(subject)
                )
            )
        case .notification:
            return .scheduleNotification(
                ScheduleNotificationInput(
                    title: reminder.title,
                    body: reminder.body,
                    fireDate: reminder.fireDate,
                    escalation: reminder.escalation,
                    requiresCompletionConfirmation: reminder.requiresConfirmation,
                    relatedTaskID: relatedTaskID(subject),
                    stageID: reminder.stageID
                )
            )
        }
    }

    private func relatedTaskID(_ subject: ReminderSubject) -> TaskItem.ID? {
        if case .task(let id) = subject.reference { return id }
        return nil
    }
}
