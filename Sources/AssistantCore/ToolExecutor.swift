import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import ExecutiveSupport
import Foundation
import PersonalMemory

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
    private let authorizer: any ToolAuthorizing
    /// The same lifecycle the UI uses. "I finished it", said to the assistant,
    /// has to end support exactly as tapping Mark complete does — one path, or
    /// one of them eventually forgets to cancel the pending reminders.
    private let followUp: FollowUpService
    /// Duplicate and conflict handling for anything the assistant remembers.
    private let memory: MemoryService
    /// Recurring responsibilities. The executor never generates occurrences
    /// itself: `createRoutine` saves the definition and asks this to reconcile,
    /// which is the same path the app takes on foreground.
    private let routines: RoutineService
    /// "Help me start", reached from a conversation instead of from a button.
    private let startSupport: StartSupportService
    private let dateProvider: any DateProvider

    public init(
        services: PlatformServices,
        repositories: AssistantRepositories,
        // The status machine is no longer reached from here: task lifecycle
        // changes go through `followUp`, which owns it. Kept as a parameter so
        // existing call sites still compile, and so a caller with its own rules
        // can pass one down.
        statusMachine: TaskStatusMachine = TaskStatusMachine(),
        authorizer: any ToolAuthorizing = SettingsToolAuthorizer(),
        followUp: FollowUpService? = nil,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.services = services
        self.repositories = repositories
        self.authorizer = authorizer
        self.memory = MemoryService(
            repository: repositories.memories,
            dateProvider: dateProvider
        )
        self.dateProvider = dateProvider
        let resolvedFollowUp = followUp
            ?? FollowUpService(
                repositories: repositories,
                services: services,
                dateProvider: dateProvider,
                coordinator: FollowUpCoordinator(statusMachine: statusMachine)
            )
        self.followUp = resolvedFollowUp
        self.routines = RoutineService(
            repositories: repositories,
            services: services,
            dateProvider: dateProvider
        )
        // The deterministic decomposer, deliberately. A model asking for "help
        // me start" already had its chance to write the steps down in the tool
        // arguments; reaching back out to a provider from inside execution
        // would put a network round trip in the middle of a side effect.
        self.startSupport = StartSupportService(
            repositories: repositories,
            followUp: resolvedFollowUp,
            dateProvider: dateProvider
        )
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
            return result(
                action,
                .denied(reason: "Not permitted by settings"),
                "Blocked: \(action.request.summary)",
                context,
                failure: .authorizationDenied
            )
        case .requiresConfirmation:
            return result(
                action,
                .awaitingConfirmation,
                "Needs your approval: \(action.request.summary)",
                context,
                failure: .confirmationRequired
            )
        case .allowed:
            break
        }

        // Permission is asked for *here*, at the moment an action needs it,
        // rather than in a queue of alerts at first launch. The user has just
        // said "put that in my calendar", so the calendar prompt arrives with
        // its reason already obvious — and someone who never mentions a
        // calendar is never asked about one.
        //
        // `ensure` prompts only when the answer is still unknown. A capability
        // the user already declined is not re-requested on every turn; it
        // fails with the reason, which the assistant can then say out loud.
        if let capability = capability(for: action.kind) {
            let status = await services.permissions.ensure(capability)
            guard status.allowsAccess else {
                return result(
                    action,
                    .denied(reason: "\(capability.rawValue) permission is \(status.rawValue)"),
                    permissionMessage(capability, status),
                    context,
                    // A capability this build does not have is not a permission
                    // the user can grant, and saying "permission denied" about
                    // it would send them to Settings for a switch that is not
                    // there. The retry policy treats both as final either way.
                    failure: status == .unsupported ? .unsupported : .permissionDenied
                )
            }
        }

        // The execution boundary. Anything a service throws stops here and
        // becomes a result — one tool failing is information for the turn, not
        // the end of it.
        do {
            return try await perform(action, context: context)
        } catch let error as PlatformError {
            return result(
                action,
                .failed(reason: String(describing: error)),
                "Failed: \(action.request.summary)",
                context,
                failure: Self.category(for: error)
            )
        } catch let error as RepositoryError {
            return result(
                action,
                .failed(reason: String(describing: error)),
                "Failed: \(action.request.summary)",
                context,
                failure: Self.category(for: error)
            )
        } catch let error as RecurrenceRule.ValidationError {
            // A rule the decoder passed and the domain refuses. Reported as a
            // validation failure rather than a transient one, so the retry
            // policy does not ask a model to propose the same impossible
            // schedule again.
            return result(
                action,
                .denied(reason: error.description),
                "Not set up: \(error.description)",
                context,
                failure: .validationFailure
            )
        } catch let error as RecurrenceInputError {
            return result(
                action,
                .denied(reason: error.description),
                "Not set up: \(error.description)",
                context,
                failure: .validationFailure
            )
        } catch is CancellationError {
            return result(
                action,
                .failed(reason: "cancelled"),
                "Stopped: \(action.request.summary)",
                context,
                failure: .cancelled
            )
        } catch {
            // Unrecognised, so treated as possibly transient rather than
            // permanently broken: the caller may try once more, and the round
            // limit stops that becoming a loop.
            return result(
                action,
                .failed(reason: String(describing: error)),
                "Failed: \(action.request.summary)",
                context,
                failure: .temporaryFailure
            )
        }
    }

    /// The platform's vocabulary in the tool layer's.
    private static func category(for error: PlatformError) -> ToolFailureCategory {
        switch error {
        case .permissionDenied:
            return .permissionDenied
        case .notAvailable:
            return .unsupported
        case .notFound:
            return .notFound
        case .invalidRequest:
            return .validationFailure
        case .underlying:
            // EventKit's save failures, an audio session that would not start:
            // real, and often gone by the next attempt.
            return .temporaryFailure
        }
    }

    private static func category(for error: RepositoryError) -> ToolFailureCategory {
        switch error {
        case .notFound:
            return .notFound
        case .storageFailure:
            return .persistenceFailure
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
                end: input.end ?? input.start.addingTimeInterval(TimeSpan.hour),
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
                snoozeDuration: minutes(input.snoozeMinutes) ?? TimeSpan.minutes(9),
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
            // Through the memory service, so what the assistant proposes goes
            // through the same duplicate and conflict handling as anything the
            // user types. A tool that wrote straight to the repository would
            // fill the Memory screen with three phrasings of the same commute.
            let write = try await memory.remember(
                MemoryItem(
                    kind: input.kind,
                    content: input.content,
                    salience: input.salience ?? 0.5,
                    tags: input.tags ?? [],
                    createdAt: context.now,
                    // The model inferring something is weaker evidence than the
                    // user saying it, and confidence follows from that.
                    source: .assistant
                )
            )
            return result(action, .executed, write.summary, context)

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
            var stored = task
            stored.estimatedDuration = minutes(input.estimatedMinutes)
            stored.preparationSteps = (input.preparationSteps ?? [])
                .resolvedSteps(parent: task.id.description)
            try await repositories.tasks.save(stored)
            return result(action, .executed, "Task tracked: \(stored.title)", context)

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
                    context,
                    // The founding rule of the product, as a failure category:
                    // only the user can say a task is done, so this is waiting
                    // on them rather than broken.
                    failure: .confirmationRequired
                )
            }
            // Through the shared lifecycle, so completing a task from a
            // conversation also cancels the reminders that were still waiting
            // for it. Doing the status change here directly would leave those
            // pending, and the user would be reminded about something they had
            // just told the assistant they had done.
            let outcome = try await followUp.handle(outcome: .completed, forTask: task.id)
            return result(action, .executed, "Completed: \(outcome.task.title)", context)

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
                end: context.now.addingTimeInterval(TimeSpan.days(7))
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

        case .createRoutine(let input):
            // Re-derived here rather than carried through the plan, because the
            // decoder's job was to reject an impossible rule, not to smuggle a
            // domain value through a `Codable` payload. Validating twice is
            // cheap; a rule that was valid at decode time and is being written
            // now is exactly the thing worth checking again.
            let rule = try input.recurrence.resolvedRule(now: context.now)
            let routineID = input.routineID ?? Routine.ID()
            let routine = Routine(
                id: routineID,
                title: input.title,
                details: input.details,
                recurrence: rule,
                importance: input.importance ?? .normal,
                recovery: recovery(for: input),
                preparationDuration: minutes(input.preparationDurationMinutes),
                travelDuration: minutes(input.travelDurationMinutes),
                preparationSteps: (input.preparationSteps ?? [])
                    .resolvedSteps(parent: routineID.description),
                createdAt: context.now
            )
            let reconciliation = try await routines.create(routine)
            let created = reconciliation.created.count
            let summary = created == 0
                ? "Routine set up: \(routine.title) — \(rule.summary(calendar: dateProvider.calendar))"
                : "Routine set up: \(routine.title) — \(rule.summary(calendar: dateProvider.calendar)). "
                    + "\(created) upcoming one\(created == 1 ? "" : "s") scheduled."
            return result(action, .executed, summary, context)

        case .addTaskDependency(let input):
            // The cycle check needs every task, which is why it happens here
            // and not in the decoder: A→B is fine on its own and catastrophic
            // if B already reaches A. Section 14.
            let all = try await repositories.tasks.tasks(matching: TaskFilter())
            let graph = TaskDependencyGraph(tasks: all)
            do {
                try graph.validate(
                    prerequisite: input.prerequisiteTaskID,
                    dependent: input.dependentTaskID
                )
            } catch let error as TaskDependencyGraph.ValidationError {
                return result(
                    action,
                    .denied(reason: error.description),
                    "Not linked: \(error.description)",
                    context,
                    failure: .validationFailure
                )
            }

            guard var dependent = all.first(where: { $0.id == input.dependentTaskID }) else {
                throw RepositoryError.notFound(input.dependentTaskID.description)
            }
            dependent.dependsOn.append(input.prerequisiteTaskID)
            dependent.updatedAt = context.now
            try await repositories.tasks.save(dependent)

            let prerequisiteTitle = all
                .first { $0.id == input.prerequisiteTaskID }?
                .title ?? "the other task"
            return result(
                action,
                .executed,
                "\"\(dependent.title)\" now waits for \"\(prerequisiteTitle)\"",
                context
            )

        case .startTask(let input):
            // Moves the task into progress and hands back one concrete thing to
            // do. It never completes anything — section 42 — and the message
            // says so plainly, because this text is what the model sees and
            // then repeats to the user.
            let support = try await startSupport.start(taskID: input.taskID)
            return result(
                action,
                .executed,
                "Started \"\(support.task.title)\" (in progress, not done). \(support.summary)",
                context
            )

        case .askClarification:
            // Unreachable through the engine, which ends the turn on a
            // clarification rather than planning it. Kept explicit — and kept
            // as a refusal — so that a future caller who builds a plan by hand
            // cannot turn a question into a silent no-op that the user never
            // sees and the model reads as done.
            return result(
                action,
                .unsupported(reason: "A clarification is asked by the assistant, not executed as an action"),
                "Not an action: \(action.request.summary)",
                context,
                failure: .unsupported
            )
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
        value.map { TimeSpan.minutes(Double($0)) }
    }

    /// How long a missed occurrence of this routine stays worth doing.
    ///
    /// A window of zero is taken literally — the user said being late is worse
    /// than skipping — while an unstated window keeps the default rather than
    /// silently turning recovery off. Section 8: the policy is the routine's,
    /// and it is deterministic either way.
    private func recovery(for input: CreateRoutineInput) -> RoutineRecoveryPolicy {
        guard let windowMinutes = input.recoveryWindowMinutes else {
            var policy = RoutineRecoveryPolicy()
            policy.allowsNextDay = input.recoveryAllowsNextDay ?? false
            return policy
        }
        guard windowMinutes > 0 else { return .none }
        return RoutineRecoveryPolicy(
            isEnabled: true,
            window: TimeSpan.minutes(Double(windowMinutes)),
            allowsNextDay: input.recoveryAllowsNextDay ?? false
        )
    }

    /// Faithfully reports whether the platform really did the thing.
    private func outcome(_ receipt: PlatformReceipt) -> ToolOutcome {
        switch receipt.fidelity {
        case .live: return .executed
        case .simulated: return .simulated(platform: receipt.platformName)
        }
    }

    /// Says what the user can do about it, which differs by status.
    ///
    /// "Not granted" is useless advice on its own: a denied capability is
    /// fixed in Settings, a restricted one cannot be fixed by this person at
    /// all, and an unsupported one is not a permission problem in the first
    /// place. This text reaches the model as a tool result and then the user,
    /// so getting it wrong sends someone hunting through Settings for a switch
    /// that is not there.
    private func permissionMessage(
        _ capability: PlatformCapability,
        _ status: PermissionStatus
    ) -> String {
        switch status {
        case .denied:
            return "Cannot \(capability.rawValue): access was declined. It can be turned back on in Settings."
        case .restricted:
            return "Cannot \(capability.rawValue): access is restricted on this device."
        case .limited:
            return "Cannot \(capability.rawValue): only partial access was granted. Full access can be turned on in Settings."
        case .unsupported:
            return "Cannot \(capability.rawValue): this device has no \(capability.rawValue) support."
        case .notDetermined, .granted:
            // `.granted` never reaches here, and `.notDetermined` only does
            // when the prompt could not be shown — the app was in the
            // background, or the request was cancelled.
            return "Cannot \(capability.rawValue): access has not been granted yet."
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
        case .storeMemory, .updateMemory, .createTask, .completeTask,
             .getUpcomingSchedule, .askClarification,
             // None of these three touch an OS API directly. They write app
             // state, and the reminder support that follows asks for
             // notification permission at the moment it schedules something —
             // which is also why declining notifications does not stop someone
             // setting up a routine.
             .createRoutine, .addTaskDependency, .startTask:
            return nil
        }
    }

    private func result(
        _ action: AssistantAction,
        _ outcome: ToolOutcome,
        _ message: String,
        _ context: AssistantContext,
        failure: ToolFailureCategory? = nil
    ) -> ToolResult {
        ToolResult(
            actionID: action.id,
            kind: action.kind,
            outcome: outcome,
            message: message,
            producedAt: context.now,
            failure: failure
        )
    }
}
