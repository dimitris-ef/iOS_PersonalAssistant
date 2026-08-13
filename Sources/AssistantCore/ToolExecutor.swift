import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import ExecutiveSupport
import Foundation

/// Runs an approved action plan.
public protocol ToolExecutor: Sendable {
    func execute(
        _ plan: AssistantActionPlan,
        context: AssistantContext
    ) async -> [ToolResult]
}

/// The default executor.
///
/// This is the only place in the application where a tool request becomes a
/// real side effect. It re-checks authorization rather than trusting the plan,
/// checks the relevant OS permission, and reports honestly — including
/// `.simulated` when the platform layer is a mock.
public struct DefaultToolExecutor: ToolExecutor {
    private let services: PlatformServices
    private let repositories: AssistantRepositories
    private let statusMachine: TaskStatusMachine
    private let authorizer: any ToolAuthorizing

    public init(
        services: PlatformServices,
        repositories: AssistantRepositories,
        statusMachine: TaskStatusMachine = TaskStatusMachine(),
        authorizer: any ToolAuthorizing = SettingsToolAuthorizer()
    ) {
        self.services = services
        self.repositories = repositories
        self.statusMachine = statusMachine
        self.authorizer = authorizer
    }

    public func execute(
        _ plan: AssistantActionPlan,
        context: AssistantContext
    ) async -> [ToolResult] {
        var results: [ToolResult] = []
        for action in plan.actions {
            results.append(await execute(action, context: context))
        }
        return results
    }

    private func execute(_ action: AssistantAction, context: AssistantContext) async -> ToolResult {
        // Never trust the authorization recorded in the plan: it may have been
        // built before the user changed settings, or by a different component.
        let authorization = authorizer.authorization(for: action.request, settings: context.settings)
        switch authorization {
        case .denied:
            return result(action, .denied(reason: "Not permitted by settings"), "Blocked: \(action.request.summary)", context)
        case .requiresConfirmation:
            return result(action, .awaitingConfirmation, "Needs your approval: \(action.request.summary)", context)
        case .allowed:
            break
        }

        if let capability = capability(for: action.kind) {
            let status = await services.permissions.status(for: capability)
            guard status == .granted else {
                return result(
                    action,
                    .denied(reason: "\(capability.rawValue) permission is \(status.rawValue)"),
                    "Cannot \(action.kind.rawValue): \(capability.rawValue) access not granted",
                    context
                )
            }
        }

        do {
            return try await perform(action, context: context)
        } catch let error as PlatformError {
            return result(action, .failed(reason: String(describing: error)), "Failed: \(action.request.summary)", context)
        } catch {
            return result(action, .failed(reason: String(describing: error)), "Failed: \(action.request.summary)", context)
        }
    }

    // MARK: Dispatch

    private func perform(_ action: AssistantAction, context: AssistantContext) async throws -> ToolResult {
        switch action.request {
        case .createCalendarEvent(let input):
            let item = CalendarItem(
                id: input.eventID ?? CalendarItem.ID(),
                title: input.title,
                start: input.start,
                end: input.end ?? input.start.addingTimeInterval(Duration.hour),
                isAllDay: input.isAllDay ?? false,
                location: input.location,
                notes: input.notes,
                importance: input.importance ?? .normal,
                travelDuration: minutes(input.travelDurationMinutes),
                preparationDuration: minutes(input.preparationDurationMinutes)
            )
            let (_, receipt) = try await services.calendar.createEvent(item)
            return result(action, outcome(receipt), receipt.description, context)

        case .updateCalendarEvent(let input):
            guard var existing = try await services.calendar.event(id: input.eventID) else {
                throw PlatformError.notFound(identifier: input.eventID.description)
            }
            if let title = input.title { existing.title = title }
            if let start = input.start { existing.start = start }
            if let end = input.end { existing.end = end }
            if let location = input.location { existing.location = location }
            if let notes = input.notes { existing.notes = notes }
            let (_, receipt) = try await services.calendar.updateEvent(existing)
            return result(action, outcome(receipt), receipt.description, context)

        case .deleteCalendarEvent(let input):
            let receipt = try await services.calendar.deleteEvent(id: input.eventID)
            return result(action, outcome(receipt), receipt.description, context)

        case .createReminder(let input):
            let item = ReminderItem(
                title: input.title,
                notes: input.notes,
                dueDate: input.dueDate,
                listName: input.listName,
                relatedTaskID: input.relatedTaskID
            )
            let (_, receipt) = try await services.reminders.createReminder(item)
            return result(action, outcome(receipt), receipt.description, context)

        case .completeReminder(let input):
            let receipt = try await services.reminders.completeReminder(id: input.reminderID)
            return result(action, outcome(receipt), receipt.description, context)

        case .createAlarm(let input):
            let request = AlarmRequest(
                label: input.label,
                fireDate: input.fireDate,
                allowsSnooze: input.allowsSnooze ?? true,
                snoozeDuration: minutes(input.snoozeMinutes) ?? Duration.minutes(9),
                maximumSnoozes: input.maximumSnoozes ?? 3
            )
            let receipt = try await services.alarms.schedule(request)
            return result(action, outcome(receipt), receipt.description, context)

        case .updateAlarm(let input):
            let alarms = try await services.alarms.scheduledAlarms()
            guard var existing = alarms.first(where: { $0.id == input.alarmID }) else {
                throw PlatformError.notFound(identifier: input.alarmID.description)
            }
            if let label = input.label { existing.label = label }
            if let fireDate = input.fireDate { existing.fireDate = fireDate }
            if let allowsSnooze = input.allowsSnooze { existing.allowsSnooze = allowsSnooze }
            let (_, receipt) = try await services.alarms.update(existing)
            return result(action, outcome(receipt), receipt.description, context)

        case .cancelAlarm(let input):
            let receipt = try await services.alarms.cancel(id: input.alarmID)
            return result(action, outcome(receipt), receipt.description, context)

        case .scheduleNotification(let input):
            let request = NotificationRequest(
                title: input.title,
                body: input.body,
                fireDate: input.fireDate,
                escalation: input.escalation ?? .standard,
                requiresCompletionConfirmation: input.requiresCompletionConfirmation ?? true,
                relatedTaskID: input.relatedTaskID,
                stageID: input.stageID
            )
            let receipt = try await services.notifications.schedule(request)
            return result(action, outcome(receipt), receipt.description, context)

        case .storeMemory(let input):
            let item = MemoryItem(
                kind: input.kind,
                content: input.content,
                salience: input.salience ?? 0.5,
                tags: input.tags ?? [],
                createdAt: context.now,
                source: .assistant
            )
            try await repositories.memories.store(item)
            return result(action, .executed, "Remembered: \(item.content)", context)

        case .updateMemory(let input):
            guard var existing = try await repositories.memories.item(id: input.memoryID) else {
                throw RepositoryError.notFound(input.memoryID.description)
            }
            if let content = input.content { existing.content = content }
            if let kind = input.kind { existing.kind = kind }
            if let tags = input.tags { existing.tags = tags }
            if let salience = input.salience { existing.salience = salience }
            existing.updatedAt = context.now
            try await repositories.memories.store(existing)
            return result(action, .executed, "Updated memory: \(existing.content)", context)

        case .createTask(let input):
            let task = TaskItem(
                id: input.taskID ?? TaskItem.ID(),
                title: input.title,
                details: input.details,
                importance: input.importance ?? .normal,
                timing: timing(for: input),
                deadline: input.dueDate,
                preparationDuration: minutes(input.preparationDurationMinutes),
                travelDuration: minutes(input.travelDurationMinutes),
                createdAt: context.now
            )
            try await repositories.tasks.save(task)
            return result(action, .executed, "Task tracked: \(task.title)", context)

        case .completeTask(let input):
            guard let task = try await repositories.tasks.task(id: input.taskID) else {
                throw RepositoryError.notFound(input.taskID.description)
            }
            // Completion requires an actual confirmation, not an inference.
            guard input.confirmedByUser ?? false else {
                return result(
                    action,
                    .denied(reason: "Completion was not confirmed by the user"),
                    "Left open (not confirmed done): \(task.title)",
                    context
                )
            }
            var plan: ReminderPlan?
            if let planID = task.reminderPlanID {
                plan = try await repositories.reminderPlans.plan(id: planID)
            }
            let transition = statusMachine.apply(.confirmedComplete(at: context.now), to: task, plan: plan)
            let updated = statusMachine.updated(task, with: transition, at: context.now)
            try await repositories.tasks.save(updated)
            return result(action, .executed, "Completed: \(updated.title)", context)

        case .createFollowUp(let input):
            guard let task = try await repositories.tasks.task(id: input.taskID) else {
                throw RepositoryError.notFound(input.taskID.description)
            }
            let notification = NotificationRequest(
                title: task.title,
                body: input.message ?? "Still open — did this get done?",
                fireDate: input.checkBackAt,
                escalation: input.escalation ?? .standard,
                requiresCompletionConfirmation: true,
                relatedTaskID: task.id
            )
            let receipt = try await services.notifications.schedule(notification)

            var updated = task
            updated.status = .needsFollowUp
            updated.followUpCount += 1
            updated.updatedAt = context.now
            try await repositories.tasks.save(updated)

            return result(action, outcome(receipt), receipt.description, context)

        case .getUpcomingSchedule(let input):
            let window = input.window ?? TimeWindow(
                start: context.now,
                end: context.now.addingTimeInterval(Duration.days(7))
            )
            let events = try await services.calendar.events(in: window)
            let tasks = try await repositories.tasks.tasks(
                matching: TaskFilter(
                    statuses: Set(TaskStatus.allCases.filter(\.isOutstanding)),
                    window: window,
                    limit: input.limit
                )
            )
            let summary = "\(events.count) event(s) and \(tasks.count) open task(s) in window"
            return result(action, .executed, summary, context)
        }
    }

    // MARK: Helpers

    private func timing(for input: CreateTaskInput) -> TimingPreference {
        if let fixed = input.fixedDate { return .fixed(fixed) }
        if let window = input.flexibleWindow { return .flexible(window) }
        if let due = input.dueDate { return .dueBy(due) }
        return .unscheduled
    }

    private func minutes(_ value: Int?) -> TimeInterval? {
        value.map { Duration.minutes(Double($0)) }
    }

    /// Faithfully reports whether the platform really did the thing.
    private func outcome(_ receipt: PlatformReceipt) -> ToolOutcome {
        switch receipt.fidelity {
        case .live: return .executed
        case .simulated: return .simulated(platform: receipt.platformName)
        }
    }

    private func capability(for kind: ToolKind) -> PlatformCapability? {
        switch kind {
        case .createCalendarEvent, .updateCalendarEvent, .deleteCalendarEvent:
            return .calendar
        case .createReminder, .completeReminder:
            return .reminders
        case .scheduleNotification, .createFollowUp:
            return .notifications
        case .createAlarm, .updateAlarm, .cancelAlarm:
            return .alarms
        case .storeMemory, .updateMemory, .createTask, .completeTask, .getUpcomingSchedule:
            return nil
        }
    }

    private func result(
        _ action: AssistantAction,
        _ outcome: ToolOutcome,
        _ message: String,
        _ context: AssistantContext
    ) -> ToolResult {
        ToolResult(
            actionID: action.id,
            kind: action.kind,
            outcome: outcome,
            message: message,
            producedAt: context.now
        )
    }
}
