import AssistantDomain
import Foundation

/// What the app is allowed to do when it has been away.
///
/// ## The failure this exists to prevent
///
/// Someone leaves the app closed for a week. A task with a two-hourly follow-up
/// ladder theoretically produced eighty-four interventions in that time. Without
/// a bound, the first thing that happens when they open the app is eighty-four
/// missed-stage transitions, an escalation level pinned at maximum, and a
/// handful of notifications arriving at once — from an assistant whose entire
/// purpose is to be the thing that does not overwhelm them.
///
/// Sections 69 to 72. The answer is not to ignore the backlog: those reminders
/// really were missed and the task really is overdue. It is to *compress* it —
/// record that the stages passed, advance escalation by a bounded amount, and
/// produce **one** current intervention.
///
/// ## Everything is here
///
/// Section 72: one type owns every threshold, so a limit cannot be raised in
/// one service and not another. Pure and injectable, so the compression
/// behaviour is testable without a clock or a database.
public struct SupportCatchUpPolicy: Hashable, Sendable {
    /// How long after its moment a pending stage is still not "missed".
    ///
    /// Sections 30 and 31. Without this, a reminder due at 09:00 that the app
    /// notices at 09:00:00.4 — because the user tapped the notification and the
    /// app launched — is marked missed a fraction of a second after firing,
    /// while the user is *looking at it*. The window has to be long enough to
    /// cover launch and delivery jitter and short enough that a genuinely
    /// ignored reminder is caught on the next foreground.
    public var missedStageGracePeriod: TimeInterval

    /// How many overdue stages of one task are applied individually.
    ///
    /// Beyond this the rest are marked missed without each one driving a fresh
    /// planning round. They still happened; they just do not each get a vote on
    /// what happens next.
    public var maximumHistoricalStagesPerTask: Int

    /// How many escalation steps one reconciliation pass may add.
    ///
    /// A week of silence is evidence that support is not working, which is
    /// worth escalating for — but jumping straight to the loudest level because
    /// of elapsed time rather than observed behaviour is how an assistant
    /// becomes frightening. Section 72.
    public var maximumEscalationStepsPerPass: Int

    /// How many tasks one pass will look at.
    ///
    /// Section 86. A background refresh has seconds, not minutes, and a store
    /// with a thousand historical tasks must not be walked in full before the
    /// app can say anything.
    public var maximumTasksPerPass: Int

    /// How far ahead OS-backed requests are scheduled.
    ///
    /// Sections 87 to 90: a rolling horizon rather than months of pre-scheduled
    /// adaptive stages. Everything past this is left in the plan, unscheduled,
    /// and picked up by a later pass — which is also what keeps the pending
    /// request count nowhere near any system limit.
    public var schedulingHorizon: TimeInterval

    /// How many times a failed hand-off to the OS is retried.
    ///
    /// Section 63. Bounded, because a scheduling call that has failed five
    /// times is not going to succeed on the sixth, and retrying it on every
    /// foreground for the life of the task is a battery bug.
    public var maximumSchedulingAttempts: Int

    public init(
        missedStageGracePeriod: TimeInterval = TimeSpan.minutes(2),
        maximumHistoricalStagesPerTask: Int = 3,
        maximumEscalationStepsPerPass: Int = 1,
        maximumTasksPerPass: Int = 100,
        schedulingHorizon: TimeInterval = TimeSpan.days(7),
        maximumSchedulingAttempts: Int = 5
    ) {
        self.missedStageGracePeriod = max(0, missedStageGracePeriod)
        self.maximumHistoricalStagesPerTask = max(1, maximumHistoricalStagesPerTask)
        self.maximumEscalationStepsPerPass = max(0, maximumEscalationStepsPerPass)
        self.maximumTasksPerPass = max(1, maximumTasksPerPass)
        self.schedulingHorizon = max(TimeSpan.hours(1), schedulingHorizon)
        self.maximumSchedulingAttempts = max(1, maximumSchedulingAttempts)
    }

    public static let `default` = SupportCatchUpPolicy()

    /// Whether a stage's moment has passed by enough to call it missed.
    ///
    /// Section 30's full condition — unresolved task, pending stage, no newer
    /// revision — is the caller's; this owns only the timing half, so the grace
    /// period cannot drift between the two places that ask.
    public func isOverdue(_ stage: ReminderStage, at now: Date) -> Bool {
        guard stage.state.isPending, let scheduled = stage.scheduledFor else { return false }
        return scheduled.addingTimeInterval(missedStageGracePeriod) <= now
    }

    /// Whether a stage is near enough to be worth telling iOS about now.
    public func isWithinHorizon(_ date: Date, from now: Date) -> Bool {
        date <= now.addingTimeInterval(schedulingHorizon)
    }

    /// Whether another scheduling attempt is allowed.
    public func permitsAnotherAttempt(_ delivery: StageDelivery) -> Bool {
        delivery.state.isRetryable && delivery.attempts < maximumSchedulingAttempts
    }
}

/// How one task's backlog was compressed.
///
/// Returned rather than merely applied, so a caller can say "you missed four
/// reminders" without recounting, and so the compression itself is assertable
/// in a test rather than inferred from side effects.
public struct SupportCatchUp: Hashable, Sendable {
    /// Every stage whose moment passed unanswered.
    public var missedStages: [ReminderStage.ID]
    /// The ones that drove a planning round. A prefix of `missedStages`.
    public var appliedStages: [ReminderStage.ID]
    /// True when the backlog was longer than the policy applies individually.
    public var wasCompressed: Bool

    public init(
        missedStages: [ReminderStage.ID] = [],
        appliedStages: [ReminderStage.ID] = [],
        wasCompressed: Bool = false
    ) {
        self.missedStages = missedStages
        self.appliedStages = appliedStages
        self.wasCompressed = wasCompressed
    }

    public var isEmpty: Bool { missedStages.isEmpty }

    /// How many were absorbed without a planning round of their own.
    public var absorbedCount: Int { missedStages.count - appliedStages.count }
}
