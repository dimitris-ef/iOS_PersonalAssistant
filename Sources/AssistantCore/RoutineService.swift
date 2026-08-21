import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import Foundation

/// What one reconciliation pass did.
public struct RoutineReconciliation: Sendable {
    /// Occurrences created because their moment is coming up.
    public var created: [TaskItem]
    /// Late occurrences still worth doing.
    public var recovering: [TaskItem]
    /// Occurrences whose window closed.
    public var expired: [TaskItem]

    public init(created: [TaskItem] = [], recovering: [TaskItem] = [], expired: [TaskItem] = []) {
        self.created = created
        self.recovering = recovering
        self.expired = expired
    }

    public var didChange: Bool {
        !created.isEmpty || !recovering.isEmpty || !expired.isEmpty
    }
}

/// Keeps recurring responsibilities alive.
///
/// ## What it does, once a cycle
///
/// 1. **Generates** the occurrences that should exist inside the horizon, and
///    only those. Idempotently: the same pass run three times produces one
///    Thursday.
/// 2. **Recovers or expires** occurrences whose moment has passed. A late one
///    that is still worth doing stays outstanding and keeps its support; one
///    whose window has closed becomes `expired`, which stops the chasing
///    without ever claiming it was done.
/// 3. **Records** how the routine itself is going — last completed, last
///    missed — while never completing or cancelling the routine, because an
///    occurrence resolving says nothing about the responsibility continuing.
///
/// ## No model, ever
///
/// Nothing here consults a provider. Section 58 makes that a hard requirement
/// and it is the right call twice over: this runs on a cold launch with no
/// network, and its behaviour has to be identical every time or the assistant
/// becomes something you cannot form a habit around.
public struct RoutineService: Sendable {
    private let repositories: AssistantRepositories
    private let services: PlatformServices
    private let scheduler: RoutineScheduler
    private let dateProvider: any DateProvider
    private let planner: any SupportPlanner
    private let logger: any ExecutiveSupportLogger

    public init(
        repositories: AssistantRepositories,
        services: PlatformServices,
        scheduler: RoutineScheduler = RoutineScheduler(),
        planner: (any SupportPlanner)? = nil,
        dateProvider: any DateProvider = SystemDateProvider(),
        logger: any ExecutiveSupportLogger = SilentExecutiveSupportLogger()
    ) {
        self.repositories = repositories
        self.services = services
        self.scheduler = scheduler
        self.planner = planner ?? DefaultSupportPlanner()
        self.dateProvider = dateProvider
        self.logger = logger
    }

    /// Creates a routine and materialises whatever it already owes.
    ///
    /// The first occurrences are generated immediately rather than at the next
    /// reconciliation, because "take medication at 9" created at 8:55 needs to
    /// work at 9.
    @discardableResult
    public func create(_ routine: Routine) async throws -> RoutineReconciliation {
        try routine.recurrence.validate()
        try await repositories.routines.save(routine)
        return try await reconcile(routine)
    }

    /// Brings every active routine up to date with the clock.
    ///
    /// Called on foreground, beside `FollowUpService.reconcile()`. The two are
    /// deliberately separate: this decides which occurrences exist, that one
    /// decides what to do about reminders that did not land.
    @discardableResult
    public func reconcileAll() async throws -> RoutineReconciliation {
        var combined = RoutineReconciliation()
        for routine in try await repositories.routines.routines(activeOnly: true) {
            let result = try await reconcile(routine)
            combined.created += result.created
            combined.recovering += result.recovering
            combined.expired += result.expired
        }
        return combined
    }

    /// One routine's occurrences, generated and reconciled.
    @discardableResult
    public func reconcile(_ routine: Routine) async throws -> RoutineReconciliation {
        let now = dateProvider.now
        let calendar = dateProvider.calendar
        let existing = try await repositories.tasks.tasks(
            matching: TaskFilter(routineID: routine.id)
        )

        var result = RoutineReconciliation()

        // 1. Generate what is missing inside the horizon.
        for occurrence in scheduler.pendingOccurrences(
            for: routine,
            existing: existing,
            now: now,
            calendar: calendar
        ) {
            try await repositories.tasks.save(occurrence)
            try await attachSupport(to: occurrence, routine: routine, now: now)
            result.created.append(occurrence)
        }

        // 2. Decide what to do about the ones whose moment has been and gone.
        var updatedRoutine = routine
        for occurrence in existing where !occurrence.status.isTerminal {
            let decision = scheduler.recoveryDecision(
                for: occurrence,
                routine: routine,
                now: now,
                calendar: calendar
            )
            guard decision != .none else { continue }

            let updated = scheduler.applying(decision, to: occurrence, at: now)
            guard updated != occurrence else { continue }
            try await repositories.tasks.save(updated)
            updatedRoutine = scheduler.routine(updatedRoutine, after: updated, at: now)

            switch decision {
            case .expire:
                // Withdraw anything still waiting. An expired occurrence with a
                // live notification is the exact behaviour section 10 forbids.
                try await cancelSupport(for: updated)
                result.expired.append(updated)
                logger.record(.occurrenceExpired(routineID: routine.id, at: now))
            case .recover(let until):
                result.recovering.append(updated)
                logger.record(.occurrenceRecovering(routineID: routine.id, until: until))
            case .none:
                break
            }
        }

        if updatedRoutine != routine {
            try await repositories.routines.save(updatedRoutine)
        }
        if result.didChange {
            logger.record(
                .routineReconciled(
                    routineID: routine.id,
                    created: result.created.count,
                    recovering: result.recovering.count,
                    expired: result.expired.count
                )
            )
        }
        return result
    }

    /// Resolves one occurrence as skipped, leaving the routine alone.
    ///
    /// "Skip the gym today" — section 105. Implemented as its own status rather
    /// than as cancellation, because cancellation reads everywhere else as
    /// calling off the responsibility.
    @discardableResult
    public func skipOccurrence(_ taskID: TaskItem.ID) async throws -> TaskItem {
        guard let task = try await repositories.tasks.task(id: taskID) else {
            throw RepositoryError.notFound(taskID.description)
        }
        let now = dateProvider.now
        let skipped = scheduler.skipping(task, at: now)
        try await repositories.tasks.save(skipped)
        try await cancelSupport(for: skipped)
        return skipped
    }

    /// Pauses a routine without deleting its history.
    @discardableResult
    public func setActive(_ isActive: Bool, routineID: Routine.ID) async throws -> Routine {
        guard var routine = try await repositories.routines.routine(id: routineID) else {
            throw RepositoryError.notFound(routineID.description)
        }
        routine.isActive = isActive
        routine.updatedAt = dateProvider.now
        try await repositories.routines.save(routine)
        return routine
    }

    // MARK: Support

    /// Gives a new occurrence the same reminder support any other task gets.
    ///
    /// Through `SupportPlanner`, not through anything routine-specific. An
    /// occurrence is a task; the reason it gets a morning-of reminder and a
    /// leave-time nudge is that every fixed-time task does.
    private func attachSupport(to occurrence: TaskItem, routine: Routine, now: Date) async throws {
        guard let date = occurrence.occurrenceDate else { return }

        let context = SupportPlanningContext(
            profile: try await repositories.profile.profile(),
            preferences: try await repositories.settings.settings().support,
            now: now,
            calendar: dateProvider.calendar
        )
        let plan = planner.makePlan(
            for: ReminderSubject(
                reference: .task(occurrence.id),
                title: routine.title,
                anchor: .moment(date),
                importance: routine.importance,
                preparationDuration: routine.preparationDuration,
                travelDuration: routine.travelDuration,
                isTimeFixed: true
            ),
            context: context
        )
        try await repositories.reminderPlans.save(plan)

        var linked = occurrence
        linked.reminderPlanID = plan.id
        try await repositories.tasks.save(linked)
    }

    /// Withdraws whatever is still pending for a resolved occurrence.
    ///
    /// Both halves matter. Cancelling the stages stops the app scheduling
    /// anything more; withdrawing the platform requests stops the notifications
    /// already sitting in iOS's queue from arriving anyway. Section 65: an
    /// expired occurrence that still buzzes at nine o'clock is worse than one
    /// that was never cancelled at all, because now the app is visibly wrong.
    private func cancelSupport(for task: TaskItem) async throws {
        guard
            let planID = task.reminderPlanID,
            var plan = try await repositories.reminderPlans.plan(id: planID)
        else { return }

        let cancelled = plan.cancelPendingStages(at: dateProvider.now)
        guard !cancelled.isEmpty else { return }
        try await repositories.reminderPlans.save(plan)

        for stage in cancelled {
            // Best effort. A stage whose request was never scheduled — the app
            // restarted, the permission was refused — is not a reason to fail
            // expiring an occurrence.
            let raw = stage.id.rawValue
            _ = try? await services.notifications.cancel(id: NotificationRequest.ID(raw))
            if stage.channel == .alarm {
                _ = try? await services.alarms.cancel(id: AlarmRequest.ID(raw))
            }
        }
    }
}
