import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import Foundation

/// What happened when a reminder outcome was processed.
public struct FollowUpResult: Sendable {
    public var task: TaskItem
    public var plan: ReminderPlan?
    /// The reminder now waiting, if the assistant scheduled one.
    public var nextReminder: ScheduledReminder?
    /// A sentence for the UI: why there is (or is not) another reminder.
    public var rationale: String?
    /// False when the outcome had already been applied and nothing changed.
    public var didChange: Bool
    /// Tasks that became workable because this one is now settled.
    ///
    /// Returned rather than merely persisted so the caller can say so — "the
    /// documents are printed, you can leave now" is the moment the dependency
    /// feature exists for, and a UI that has to poll for it would miss it.
    public var unblocked: [TaskItem]

    public init(
        task: TaskItem,
        plan: ReminderPlan?,
        nextReminder: ScheduledReminder? = nil,
        rationale: String? = nil,
        didChange: Bool = true,
        unblocked: [TaskItem] = []
    ) {
        self.task = task
        self.plan = plan
        self.nextReminder = nextReminder
        self.rationale = rationale
        self.didChange = didChange
        self.unblocked = unblocked
    }
}

/// The application-level entry point for "something happened to a reminder".
///
/// Everything that can change a task's support lifecycle comes through here:
/// the UI's Snooze and Dismiss buttons, the assistant's `completeTask` tool,
/// and — once the Apple layer exists — notification callbacks. One door, so the
/// rule that dismissing is not completing cannot be routed around by adding a
/// button.
///
/// It does the I/O and nothing else. The decision belongs to
/// ``FollowUpCoordinator``, which is pure; this loads, persists and asks the
/// platform layer to schedule. Splitting it that way is why the policy can be
/// tested exhaustively without a database.
public struct FollowUpService: Sendable {
    private let repositories: AssistantRepositories
    private let services: PlatformServices
    private let coordinator: FollowUpCoordinator
    private let dateProvider: any DateProvider
    private let timing: FollowUpTiming

    public init(
        repositories: AssistantRepositories,
        services: PlatformServices,
        dateProvider: any DateProvider = SystemDateProvider(),
        timing: FollowUpTiming = .default,
        coordinator: FollowUpCoordinator? = nil
    ) {
        self.repositories = repositories
        self.services = services
        self.dateProvider = dateProvider
        self.timing = timing
        self.coordinator = coordinator
            ?? FollowUpCoordinator(planner: DefaultSupportPlanner(timing: timing))
    }

    /// Processes an outcome reported against one reminder.
    ///
    /// `stageID` is nil when the user acted on the task directly — tapping
    /// "Mark complete" in the task list rather than answering a notification.
    /// The lifecycle is the same either way, which is the point: the UI has no
    /// private path to a task's status.
    ///
    /// `revision` is the plan revision the *caller* believes it is answering
    /// about. A notification carries the revision it was scheduled under, so a
    /// button pressed on a reminder that has since been replaced arrives with a
    /// stale number and is declined (section 18). Nil means "I have no claim
    /// about which revision this is" — the UI's own buttons, which are looking
    /// at current state — and is always accepted.
    @discardableResult
    public func handle(
        outcome: ReminderOutcome,
        forTask taskID: TaskItem.ID,
        stageID: ReminderStage.ID? = nil,
        revision: Int? = nil
    ) async throws -> FollowUpResult {
        guard let task = try await repositories.tasks.task(id: taskID) else {
            throw RepositoryError.notFound(taskID.description)
        }

        guard let planID = task.reminderPlanID,
              let plan = try await repositories.reminderPlans.plan(id: planID)
        else {
            // No plan to update, but the task still deserves the status change:
            // completing a task that was never given reminders still completes
            // it.
            return try await applyWithoutPlan(outcome: outcome, task: task)
        }

        // Section 18. A callback from a superseded plan must not mutate the
        // current one. The classic sequence: stage A is scheduled, the event
        // moves, A is replaced by B — and then the notification for A, which
        // has been sitting on the lock screen the whole time, is finally
        // tapped. Applying it would resurrect a reminder that no longer exists
        // and, worse, could reopen support the user has already settled.
        //
        // Only a *lower* revision is refused. A higher one cannot legitimately
        // happen, and if it somehow did — a restored backup, a clock that went
        // backwards — refusing it would be the app arguing with the user about
        // a button they just pressed.
        if let revision, revision < plan.revision {
            return FollowUpResult(task: task, plan: plan, didChange: false)
        }

        // Sections 49 to 52. Notification callbacks arrive more than once: iOS
        // can redeliver after a crash, a cold launch triggered by a lock-screen
        // action can race a foreground pass doing the same work, and the user
        // can tap twice. The claim is persistent and derived from (stage,
        // action, revision), so the second arrival — in this process or the
        // next — finds the row already there and changes nothing.
        //
        // Only stage-addressed outcomes are claimed. An action taken in the UI
        // has no stage and no duplicate to defend against: the user pressing
        // "Done" twice is looking at a task that is already done.
        if let stageID {
            let claim = HandledSupportAction(
                stageID: stageID,
                taskID: task.id,
                action: Self.actionName(for: outcome),
                revision: plan.revision,
                handledAt: dateProvider.now
            )
            let isFirst = (try? await repositories.supportActions.claim(claim)) ?? true
            guard isFirst else {
                return FollowUpResult(task: task, plan: plan, didChange: false)
            }
        }

        var decision = coordinator.apply(
            outcome: outcome,
            toStage: stageID,
            task: task,
            plan: plan,
            context: try await planningContext()
        )
        // One change to the plan, one bump. Recorded here rather than inside
        // the coordinator so the pure decision stays a pure function of its
        // inputs — a coordinator that incremented a counter would return a
        // different value for the same arguments.
        if decision.didChange { decision.plan.touch() }

        try await persist(decision)

        return FollowUpResult(
            task: decision.task,
            plan: decision.plan,
            nextReminder: decision.schedule.first,
            rationale: decision.rationale,
            didChange: decision.didChange,
            unblocked: try await unblock(after: decision.task)
        )
    }

    /// Brings pending reminders up to date with the clock, for one task at a
    /// time.
    ///
    /// ## Where the whole-store version went
    ///
    /// This used to walk every outstanding task and is now the per-task half of
    /// that job, because Part 11 needs the sweep to do more than reminders:
    /// routines have to be generated first, the OS schedule has to be diffed
    /// afterwards, and the whole thing has to be single-flighted, bounded and
    /// cancellable. That belongs in ``SupportReconciliationService``, which
    /// owns the order (section 59) and calls the same pure coordinator this
    /// does.
    ///
    /// What is left here is what the *engine* needs: bringing one task up to
    /// date immediately after acting on it, without waiting for a pass.
    @discardableResult
    public func reconcile(
        task taskID: TaskItem.ID,
        policy: SupportCatchUpPolicy = .default
    ) async throws -> FollowUpResult? {
        guard let task = try await repositories.tasks.task(id: taskID) else { return nil }
        guard
            let planID = task.reminderPlanID,
            let plan = try await repositories.reminderPlans.plan(id: planID)
        else { return nil }

        let outcome = coordinator.reconcile(
            task: task,
            plan: plan,
            context: try await planningContext(),
            policy: policy
        )
        guard outcome.didChange else { return nil }

        try await repositories.reminderPlans.save(outcome.plan)
        try await repositories.tasks.save(outcome.task)

        for stage in outcome.cancel {
            await cancelPlatformRequest(for: stage)
        }
        for reminder in outcome.schedule {
            try await schedulePlatformRequest(
                for: reminder,
                task: outcome.task,
                revision: outcome.plan.revision
            )
        }

        return FollowUpResult(
            task: outcome.task,
            plan: outcome.plan,
            nextReminder: outcome.schedule.first,
            rationale: outcome.rationale
        )
    }

    /// A stable name for an outcome, for the handled-action identity.
    ///
    /// Spelled out rather than derived from the enum, because the associated
    /// values must not enter it: two snoozes to different times are still one
    /// "the user pressed Snooze on this stage", and letting the target date
    /// into the identity would make every repeat a distinct action and defeat
    /// the whole mechanism.
    static func actionName(for outcome: ReminderOutcome) -> String {
        switch outcome {
        case .delivered: return "delivered"
        case .snoozed: return "snoozed"
        case .dismissed: return "dismissed"
        case .acknowledged: return "acknowledged"
        case .missed: return "missed"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        }
    }

    // MARK: Persistence and platform

    /// Writes the decision and tells the platform layer about it.
    ///
    /// Task and plan are written together, plan first. The repositories are
    /// separate protocols with no shared transaction — the SwiftData backend
    /// commits each call — so a crash between the two writes is possible. The
    /// order makes that recoverable rather than dangerous: a saved plan with an
    /// unsaved task leaves a pending follow-up on a task whose status is stale,
    /// which reconciliation corrects. The reverse would leave a resolved task
    /// with live reminders, which is the failure that actually bothers a user.
    private func persist(
        _ decision: FollowUpDecision,
        scheduling extra: [ScheduledReminder]? = nil
    ) async throws {
        guard decision.didChange else { return }

        try await repositories.reminderPlans.save(decision.plan)
        try await repositories.tasks.save(decision.task)

        // Withdraw first, so a rescheduled reminder never overlaps the one it
        // replaces.
        for stage in decision.cancel {
            await cancelPlatformRequest(for: stage)
        }
        for reminder in extra ?? decision.schedule {
            try await schedulePlatformRequest(
                for: reminder,
                task: decision.task,
                revision: decision.plan.revision
            )
        }
    }

    /// Hands the reminder to the platform abstraction.
    ///
    /// The domain decided *what* and *when*; this decides only which service
    /// delivers it. Today every one of them is a mock that records the request
    /// and reports `.simulated`, so nothing here reaches a real device — and
    /// swapping in the Apple implementations later changes this method and
    /// nothing above it.
    private func schedulePlatformRequest(
        for reminder: ScheduledReminder,
        task: TaskItem,
        revision: Int
    ) async throws {
        switch reminder.channel {
        case .alarm:
            _ = try await services.alarms.schedule(
                AlarmRequest(
                    id: AlarmRequest.ID(reminder.stageID.rawValue),
                    label: reminder.title,
                    fireDate: reminder.fireDate,
                    allowsSnooze: true,
                    relatedTaskID: task.id,
                    planRevision: revision
                )
            )
        case .notification, .reminderList:
            _ = try await services.notifications.schedule(
                NotificationRequest(
                    // The stage id *is* the request id. That is what makes
                    // cancelling a reminder possible without keeping a second
                    // mapping table, and what stops a re-run creating a second
                    // OS-level notification for the same stage.
                    id: NotificationRequest.ID(reminder.stageID.rawValue),
                    title: reminder.title,
                    body: reminder.body,
                    fireDate: reminder.fireDate,
                    escalation: reminder.escalation,
                    requiresCompletionConfirmation: reminder.requiresConfirmation,
                    relatedTaskID: task.id,
                    stageID: reminder.stageID,
                    // Carried into `userInfo` so the answer that comes back can
                    // be checked against the plan as it stands then. See
                    // `handle(outcome:forTask:stageID:revision:)`.
                    planRevision: revision
                )
            )
        }
    }

    /// Best-effort withdrawal. A reminder that was never scheduled — because
    /// the app restarted, or the stage predates this feature — is not an error
    /// worth failing a completion over.
    private func cancelPlatformRequest(for stage: ReminderStage) async {
        let raw = stage.id.rawValue
        _ = try? await services.notifications.cancel(id: NotificationRequest.ID(raw))
        if stage.channel == .alarm {
            _ = try? await services.alarms.cancel(id: AlarmRequest.ID(raw))
        }
    }

    /// The status change for a task with no reminder plan.
    private func applyWithoutPlan(
        outcome: ReminderOutcome,
        task: TaskItem
    ) async throws -> FollowUpResult {
        let decision = coordinator.apply(
            outcome: outcome,
            toStage: nil,
            task: task,
            // An empty plan carrying the task's own subject, so the status
            // machine still reads real policies rather than defaults invented
            // here.
            plan: ReminderPlan(
                subject: ReminderSubject(
                    reference: .task(task.id),
                    title: task.title,
                    anchor: .unscheduled,
                    importance: task.importance
                ),
                stages: [],
                createdAt: dateProvider.now,
                generatedBy: "no-plan"
            ),
            context: try await planningContext()
        )

        guard decision.didChange else {
            return FollowUpResult(task: task, plan: nil, didChange: false)
        }

        // Only the task is kept. The synthetic plan exists so the status
        // machine reads real policies rather than defaults invented here, but
        // it is not stored and neither is anything the planner hung off it: a
        // reminder attached to a plan nobody can look up would be scheduled and
        // then never resolvable. A task with no reminder plan gets its status
        // change and nothing else — which is correct, because nothing ever
        // offered to remind the user about it.
        try await repositories.tasks.save(decision.task)
        return FollowUpResult(
            task: decision.task,
            plan: nil,
            rationale: decision.rationale,
            unblocked: try await unblock(after: decision.task)
        )
    }

    // MARK: Dependencies

    /// Re-evaluates whatever was waiting on this task.
    ///
    /// Runs on every settlement, not only on completion. A prerequisite that
    /// was skipped or has expired is never going to be completed either, and
    /// leaving its dependents blocked forever would turn one missed step into a
    /// permanently stuck list — section 15's nagging problem inverted.
    ///
    /// Each newly workable task gets its status nudged off `notStarted` so the
    /// change is visible and persisted; support for it is planned the next time
    /// something happens to it, exactly as for any other task. Section 16 asks
    /// that the user not have to reopen the app for this, and this is what
    /// makes that true — the work happens when the prerequisite resolves, not
    /// when a screen appears.
    private func unblock(after task: TaskItem) async throws -> [TaskItem] {
        guard task.status.isSettled else { return [] }

        let all = try await repositories.tasks.tasks(matching: TaskFilter())
        let graph = TaskDependencyGraph(tasks: all)
        let newly = graph.unblocked(by: task.id)
        guard !newly.isEmpty else { return [] }

        var updated: [TaskItem] = []
        for var candidate in newly {
            candidate.updatedAt = dateProvider.now
            try await repositories.tasks.save(candidate)
            updated.append(candidate)
        }
        return updated
    }

    private func planningContext() async throws -> SupportPlanningContext {
        SupportPlanningContext(
            profile: try await repositories.profile.profile(),
            preferences: try await repositories.settings.settings().support,
            now: dateProvider.now,
            calendar: dateProvider.calendar
        )
    }
}
