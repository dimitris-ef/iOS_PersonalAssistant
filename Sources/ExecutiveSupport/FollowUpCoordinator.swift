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

/// What one task's reconciliation concluded.
///
/// Deliberately not a `[FollowUpDecision]`. The earlier shape returned one
/// decision per overdue stage and left the caller to work out which schedules
/// to honour — and the caller honoured all of them, which is how a week's
/// absence became a screenful of notifications. One value, one intervention,
/// with the backlog described rather than enacted.
public struct ReconciledSupport: Sendable {
    public var task: TaskItem
    public var plan: ReminderPlan
    /// The single current intervention, if there is one.
    public var schedule: [ScheduledReminder]
    /// Stages whose platform requests should be withdrawn — including the
    /// intermediate ones this pass created and then superseded.
    public var cancel: [ReminderStage]
    /// What the backlog looked like, for the log and for the banner.
    public var catchUp: SupportCatchUp
    public var rationale: String?
    public var didChange: Bool

    public init(
        task: TaskItem,
        plan: ReminderPlan,
        schedule: [ScheduledReminder] = [],
        cancel: [ReminderStage] = [],
        catchUp: SupportCatchUp = SupportCatchUp(),
        rationale: String? = nil,
        didChange: Bool = true
    ) {
        self.task = task
        self.plan = plan
        self.schedule = schedule
        self.cancel = cancel
        self.catchUp = catchUp
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
        //
        // It applies only to outcomes *about the reminder*. Completing and
        // cancelling are statements about the task, and must land whatever the
        // named stage has already been through: someone who dismissed a
        // reminder at 6:00 and taps Done at 6:05 on the same sheet has finished
        // the task, and swallowing that because the stage was resolved would
        // leave them being chased about work they had done.
        if let stageID, !outcome.resolvesTask {
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

    /// Brings one task's reminders up to date with the clock, bounded.
    ///
    /// ## The reconciliation path
    ///
    /// Real notification callbacks are late, dropped, or never delivered at all
    /// — the app may simply not have been running — so the truth about a
    /// reminder cannot come only from a callback. Anything still `pending` well
    /// past its moment, on an unresolved task, is missed, and missed means the
    /// assistant tries again.
    ///
    /// ## Why this returns one decision and not one per stage
    ///
    /// Sections 69 to 71, and it is the difference between an assistant and an
    /// alarm system. Someone who has not opened the app for a week may have
    /// eighty-four theoretically-missed follow-ups on one task. The earlier
    /// version of this method applied each of them and returned a decision for
    /// each, and the caller scheduled every one — eighty-four notifications, at
    /// once, for a person whose difficulty with being overwhelmed is the reason
    /// this app exists.
    ///
    /// So the backlog is *compressed*:
    ///
    /// - every overdue stage is recorded as missed, because it was;
    /// - only the most recent few drive a planning round;
    /// - escalation may climb, but by a bounded amount per pass;
    /// - exactly one intervention is scheduled, and it is the current one.
    ///
    /// The whole backlog still shows in the plan's history. What it does not do
    /// is arrive in the notification centre.
    ///
    /// Applying this twice is a no-op: the first pass leaves those stages
    /// resolved, and a resolved stage takes no further outcome.
    public func reconcile(
        task: TaskItem,
        plan: ReminderPlan,
        context: SupportPlanningContext,
        policy: SupportCatchUpPolicy = .default
    ) -> ReconciledSupport {
        guard !task.status.isTerminal else {
            return ReconciledSupport(task: task, plan: plan, didChange: false)
        }

        let overdue = plan.stages
            .filter { policy.isOverdue($0, at: context.now) }
            .sorted { ($0.scheduledFor ?? .distantPast) < ($1.scheduledFor ?? .distantPast) }

        guard !overdue.isEmpty else {
            return ReconciledSupport(task: task, plan: plan, didChange: false)
        }

        // The oldest are absorbed: recorded as missed and counted, but they do
        // not each get a vote on what happens next. The most recent few run
        // through the full pipeline, because those are the ones whose outcome
        // describes the situation the user is actually in.
        let appliedCount = min(overdue.count, policy.maximumHistoricalStagesPerTask)
        let absorbed = overdue.dropLast(appliedCount)
        let applied = overdue.suffix(appliedCount)

        var currentTask = task
        var currentPlan = plan
        // The loudest level this plan had already reached before the pass. The
        // ceiling is measured from here rather than from the task, because
        // escalation lives on stages: it is a property of how the assistant has
        // been interrupting, not of the task itself.
        let startingEscalation = plan.stages.map(\.escalation).max() ?? .gentle

        for stage in absorbed {
            guard currentPlan.recordOutcome(.missed, forStage: stage.id, at: context.now) else {
                continue
            }
            // The counters still move — a missed reminder is a missed reminder
            // whether or not it got its own planning round — so the escalation
            // the user eventually sees reflects what really happened.
            let transition = statusMachine.apply(
                event(for: .missed, at: context.now),
                to: currentTask,
                plan: currentPlan
            )
            currentTask = statusMachine.updated(currentTask, with: transition, at: context.now)
        }

        // Everything the plan already had. What is *not* in this set after the
        // loop below was created by this pass, which is what makes the
        // intermediate rounds distinguishable from the plan's own future stages.
        let preexisting = Set(plan.stages.map(\.id))

        var lastDecision: FollowUpDecision?
        /// The newest intervention any round actually produced.
        ///
        /// Tracked separately from `lastDecision` because a round can change
        /// the plan without scheduling anything: the planner declines when an
        /// equivalent follow-up is already waiting, and inside one pass every
        /// round computes its delay from the same `context.now`, so the second
        /// and third rounds routinely land on the moment the first already
        /// claimed. Reading the schedule off the *last* decision would then see
        /// an empty list and conclude there was nothing to keep — cancelling
        /// the one real follow-up the pass had produced.
        var lastScheduled: ScheduledReminder?
        for stage in applied {
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
            lastDecision = decision
            if let reminder = decision.schedule.first { lastScheduled = reminder }
        }

        // Only the newest intervention survives. Each applied round appended a
        // follow-up as it went, all of them dated *after* the pass began, so
        // leaving them pending would have the scheduler hand every one of them
        // to iOS and the compression would have been cosmetic — the backlog
        // would arrive as three notifications instead of twelve.
        //
        // Scoped to stages this pass created. A plan's own future stages — the
        // final call at the deadline, still legitimately waiting — are not this
        // method's to withdraw just because an earlier nudge was missed.
        let keeping = lastScheduled?.stageID
        var superseded: [ReminderStage] = []
        for index in currentPlan.stages.indices
        where currentPlan.stages[index].state.isPending
            && !preexisting.contains(currentPlan.stages[index].id)
            && currentPlan.stages[index].id != keeping
        {
            superseded.append(currentPlan.stages[index])
            currentPlan.stages[index].transition(to: .cancelled, at: context.now)
        }

        // Section 72: elapsed time is evidence that support is not working, and
        // worth escalating for — but jumping to the loudest level because a week
        // passed, rather than because of anything the user did, is how an
        // assistant becomes frightening.
        //
        // Applied to the stage in the plan as well as to the reminder being
        // scheduled, so what is persisted and what is delivered agree. Clamping
        // only the outgoing request would leave the plan claiming a level the
        // user never actually got.
        let ceiling = Self.clamp(
            .alarm,
            from: startingEscalation,
            steps: policy.maximumEscalationStepsPerPass
        )
        for index in currentPlan.stages.indices
        where currentPlan.stages[index].state.isPending
            && currentPlan.stages[index].escalation > ceiling {
            currentPlan.stages[index].escalation = ceiling
            if ceiling < .alarm, currentPlan.stages[index].channel == .alarm {
                currentPlan.stages[index].channel = .notification
            }
        }

        currentPlan.touch()

        return ReconciledSupport(
            task: currentTask,
            plan: currentPlan,
            schedule: lastScheduled.map { reminder in
                var adjusted = reminder
                adjusted.escalation = min(adjusted.escalation, ceiling)
                if adjusted.escalation < .alarm, adjusted.channel == .alarm {
                    adjusted.channel = .notification
                }
                return [adjusted]
            } ?? [],
            cancel: superseded,
            catchUp: SupportCatchUp(
                missedStages: overdue.map(\.id),
                appliedStages: applied.map(\.id),
                wasCompressed: !absorbed.isEmpty
            ),
            rationale: lastDecision?.rationale,
            didChange: true
        )
    }

    /// Holds an escalation level to within `steps` of where it started.
    static func clamp(
        _ level: EscalationLevel,
        from starting: EscalationLevel,
        steps: Int
    ) -> EscalationLevel {
        guard level.rank > starting.rank + steps else { return level }
        let capped = starting.rank + steps
        return EscalationLevel.allCases.first { $0.rank == capped } ?? level
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
