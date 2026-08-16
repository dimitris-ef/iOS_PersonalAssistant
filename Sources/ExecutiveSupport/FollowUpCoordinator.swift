import AssistantDomain
import Foundation

/// Everything one reminder outcome changes.
///
/// A value, not a set of side effects. The caller persists the task and the
/// plan and asks the platform layer to schedule and cancel — which means the
/// entire decision is testable without a repository, a clock or a notification
/// centre in sight.
public struct FollowUpDecision: Sendable {
    /// The task after the status machine has had its say.
    public var task: TaskItem
    /// The plan with the outcome recorded and any new stage appended.
    public var plan: ReminderPlan
    /// Reminders the platform layer should now schedule.
    public var schedule: [ScheduledReminder]
    /// Stages whose platform requests should be withdrawn.
    public var cancel: [ReminderStage]
    /// Why the assistant is doing this, for the timeline and the log.
    public var rationale: String?
    /// False when the outcome had already been applied.
    ///
    /// The signal that made this operation idempotent: a repeated callback
    /// produces a decision that changes nothing and schedules nothing.
    public var didChange: Bool

    public init(
        task: TaskItem,
        plan: ReminderPlan,
        schedule: [ScheduledReminder] = [],
        cancel: [ReminderStage] = [],
        rationale: String? = nil,
        didChange: Bool = true
    ) {
        self.task = task
        self.plan = plan
        self.schedule = schedule
        self.cancel = cancel
        self.rationale = rationale
        self.didChange = didChange
    }
}

/// Runs one reminder outcome through the whole support lifecycle.
///
/// This is the join between the two systems that already existed and never
/// spoke to each other. `TaskStatusMachine` knew that dismissing is not
/// completing; `SupportPlanner` knew how to build reminders. Nothing turned the
/// first into the second, so support ended when a notification was posted.
///
/// The order is fixed and worth stating, because getting it wrong is how a
/// completed task acquires a follow-up:
///
///   1. the stage records what happened to it
///   2. the status machine decides what that means for the task
///   3. if the task is now resolved, every pending reminder is cancelled
///   4. otherwise the planner is asked for one next intervention
///
/// Pure and synchronous. It reads a clock it is handed, never `Date()`.
public struct FollowUpCoordinator: Sendable {
    private let statusMachine: TaskStatusMachine
    private let planner: any SupportPlanner

    public init(
        statusMachine: TaskStatusMachine = TaskStatusMachine(),
        planner: any SupportPlanner = DefaultSupportPlanner()
    ) {
        self.statusMachine = statusMachine
        self.planner = planner
    }

    /// Applies an outcome reported against one reminder stage.
    public func apply(
        outcome: ReminderOutcome,
        toStage stageID: ReminderStage.ID?,
        task: TaskItem,
        plan: ReminderPlan,
        context: SupportPlanningContext
    ) -> FollowUpDecision {
        var plan = plan

        // A stale callback for a task that is already finished. Recording it
        // would be harmless, but scheduling anything from it would not: this is
        // the path by which a completed task acquires a 7:30 PM reminder.
        guard !task.status.isTerminal else {
            if let stageID {
                plan.recordOutcome(.cancelled, forStage: stageID, at: context.now)
            }
            return FollowUpDecision(task: task, plan: plan, didChange: false)
        }

        // Idempotency. A stage that already carries an outcome does not take a
        // second one, so a notification callback delivered twice — which real
        // ones are — produces one follow-up, not two.
        if let stageID {
            let recorded = plan.recordOutcome(
                stageState(for: outcome),
                forStage: stageID,
                at: context.now
            )
            guard recorded else {
                return FollowUpDecision(task: task, plan: plan, didChange: false)
            }
        }

        // What the outcome means for the task, decided in the one place that
        // decides such things.
        let transition = statusMachine.apply(event(for: outcome, at: context.now), to: task, plan: plan)
        let updatedTask = statusMachine.updated(task, with: transition, at: context.now)

        if updatedTask.status.isTerminal {
            // Resolution ends support, in the data rather than in the UI. The
            // cancelled stages come back so their platform requests can be
            // withdrawn too.
            let cancelled = plan.cancelPendingStages(at: context.now)
            return FollowUpDecision(
                task: updatedTask,
                plan: plan,
                cancel: cancelled,
                rationale: updatedTask.status == .completed
                    ? "Done — nothing further scheduled."
                    : "Cancelled — nothing further scheduled."
            )
        }

        guard
            let intervention = planner.nextIntervention(
                for: updatedTask,
                plan: plan,
                outcome: outcome,
                context: context
            )
        else {
            return FollowUpDecision(task: updatedTask, plan: plan)
        }

        // The status machine may have raised the level after repeated snoozes
        // or misses. It wins over the planner's own reading: it is the one that
        // has been counting.
        var stage = intervention.stage
        if let escalation = transition.nextEscalation, escalation > stage.escalation {
            stage.escalation = escalation
            stage.channel = escalation >= .alarm ? .alarm : stage.channel
        }

        plan.stages.append(stage)

        return FollowUpDecision(
            task: updatedTask,
            plan: plan,
            schedule: [scheduledReminder(for: stage, plan: plan)],
            rationale: intervention.rationale
        )
    }

    /// Marks pending reminders whose moment has passed as missed.
    ///
    /// The reconciliation path. Real notification callbacks will be late,
    /// dropped or never delivered at all — the app may simply not have been
    /// running — so the truth about a reminder cannot come only from a
    /// callback. Anything still `pending` after its scheduled time, on an
    /// unresolved task, is missed, and missed means the assistant tries again.
    ///
    /// Returns one decision per stage that needed it, or an empty array when
    /// there is nothing overdue. Applying it twice is a no-op, because the
    /// first pass leaves those stages resolved.
    public func reconcile(
        task: TaskItem,
        plan: ReminderPlan,
        context: SupportPlanningContext
    ) -> [FollowUpDecision] {
        guard !task.status.isTerminal else { return [] }

        let overdue = plan.pendingStages
            .filter { stage in
                guard let scheduled = stage.scheduledFor else { return false }
                return scheduled <= context.now
            }
            .sorted { ($0.scheduledFor ?? .distantPast) < ($1.scheduledFor ?? .distantPast) }

        guard !overdue.isEmpty else { return [] }

        // Applied one at a time, feeding each result into the next, so the
        // attempt count climbs and a backlog of three missed reminders
        // escalates rather than producing three identical follow-ups.
        var decisions: [FollowUpDecision] = []
        var currentTask = task
        var currentPlan = plan

        for stage in overdue {
            let decision = apply(
                outcome: .missed,
                toStage: stage.id,
                task: currentTask,
                plan: currentPlan,
                context: context
            )
            guard decision.didChange else { continue }
            currentTask = decision.task
            currentPlan = decision.plan
            decisions.append(decision)
        }

        return decisions
    }

    // MARK: Translation

    /// Reminder outcome → what it does to the stage.
    private func stageState(for outcome: ReminderOutcome) -> ReminderStageState {
        switch outcome {
        case .delivered: return .delivered
        case .snoozed: return .snoozed
        case .dismissed: return .dismissed
        case .acknowledged: return .acknowledged
        case .missed: return .missed
        case .completed, .cancelled: return .cancelled
        }
    }

    /// Reminder outcome → what it does to the task.
    ///
    /// The mapping that carries the product's central rule: `.dismissed` maps
    /// to `.reminderDismissed`, which the status machine turns into
    /// `needsFollowUp` — never `completed`.
    private func event(for outcome: ReminderOutcome, at now: Date) -> EngagementEvent {
        switch outcome {
        case .delivered:
            return .reminderDelivered(at: now)
        case .snoozed(let until):
            return .snoozed(until: until ?? now)
        case .dismissed:
            return .reminderDismissed(at: now)
        case .acknowledged:
            return .startedWorking(at: now)
        case .missed:
            return .reminderMissed(at: now)
        case .completed:
            return .confirmedComplete(at: now)
        case .cancelled:
            return .cancelled(at: now)
        }
    }

    private func scheduledReminder(for stage: ReminderStage, plan: ReminderPlan) -> ScheduledReminder {
        ScheduledReminder(
            planID: plan.id,
            stageID: stage.id,
            kind: stage.kind,
            fireDate: stage.scheduledFor ?? plan.createdAt,
            channel: stage.channel,
            title: plan.subject.title,
            body: stage.message,
            escalation: stage.escalation,
            requiresConfirmation: stage.requiresConfirmation
                || plan.completion.requiresExplicitConfirmation
        )
    }
}
