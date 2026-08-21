import AssistantDomain
import Foundation

/// Every number that decides when the assistant comes back.
///
/// One value type, in one file, so "how long until the next nudge?" has a
/// single answer that a test can set and a person can read. The alternative —
/// intervals sprinkled through the planner, the status machine and a view
/// model — is how a support system ends up nagging every four hours about
/// something due in ten minutes, with no one place to look.
///
/// The rules are deterministic. No model is consulted to decide whether a
/// dismissed reminder should come back: that has to work offline, instantly,
/// and identically every time.
public struct FollowUpTiming: Hashable, Sendable {
    /// How long to wait before the next attempt, by how much the task matters.
    ///
    /// The gap between `low` and `critical` is the whole point. Chasing someone
    /// every fifteen minutes about a low-priority errand is the behaviour that
    /// makes people turn an assistant off.
    public var interval: [Importance: TimeInterval]

    /// Multiplier applied per unsuccessful attempt.
    ///
    /// Below 1, so repeated silence tightens the loop rather than loosening it.
    /// Bounded by ``minimumInterval`` — this shrinks, it does not converge on
    /// zero.
    public var repeatedAttemptFactor: Double

    /// The floor. However urgent and however many attempts, the assistant does
    /// not interrupt more often than this.
    public var minimumInterval: TimeInterval

    /// When a deadline is closer than the computed interval, the follow-up is
    /// pulled in to this fraction of the remaining time.
    ///
    /// Without it a reminder dismissed at 9:50 PM for a 10:00 PM deadline would
    /// come back at 11:50 PM — after the thing it was about.
    public var deadlineFraction: Double

    /// How long after a deadline has already passed to wait before checking in
    /// on an overdue task. Short, but not instant: something overdue by a
    /// minute is often being done right now.
    public var overdueInterval: TimeInterval

    /// How long to leave someone alone once they say they are working on it.
    public var inProgressCheckIn: TimeInterval

    /// After this many unsuccessful attempts, ask for explicit confirmation
    /// rather than just reminding.
    public var confirmationAfterAttempts: Int

    /// The loudest this is ever allowed to get.
    ///
    /// Adaptive is not the same as unbounded. Without a ceiling, "one step per
    /// attempt" means a task ignored six times eventually reaches whatever the
    /// noisiest level in the enum is and stays there — which is how a support
    /// tool turns into something people disable. Section 29.
    public var maximumEscalation: EscalationLevel

    /// How many interventions one task may produce in a rolling day.
    ///
    /// The other half of boundedness. Escalation controls how loud; this
    /// controls how often, and it is the one that prevents a reminder storm
    /// when several missed stages reconcile at once.
    public var maximumInterventionsPerDay: Int

    /// Extra weight, in attempts, carried by a reminder the user actively
    /// swiped away versus one they never saw.
    ///
    /// Dismissal and silence are different signals. Someone who dismissed three
    /// reminders has decided not to act three times, which calls for a
    /// different approach sooner than three notifications that arrived while
    /// their phone was face-down in a bag.
    public var dismissalWeight: Int

    public init(
        interval: [Importance: TimeInterval] = FollowUpTiming.defaultIntervals,
        repeatedAttemptFactor: Double = 0.5,
        minimumInterval: TimeInterval = TimeSpan.minutes(10),
        deadlineFraction: Double = 0.5,
        overdueInterval: TimeInterval = TimeSpan.minutes(30),
        inProgressCheckIn: TimeInterval = TimeSpan.minutes(45),
        confirmationAfterAttempts: Int = 2,
        maximumEscalation: EscalationLevel = .alarm,
        maximumInterventionsPerDay: Int = 6,
        dismissalWeight: Int = 1
    ) {
        self.interval = interval
        self.repeatedAttemptFactor = repeatedAttemptFactor
        self.minimumInterval = minimumInterval
        self.deadlineFraction = deadlineFraction
        self.overdueInterval = overdueInterval
        self.inProgressCheckIn = inProgressCheckIn
        self.confirmationAfterAttempts = confirmationAfterAttempts
        self.maximumEscalation = maximumEscalation
        self.maximumInterventionsPerDay = maximumInterventionsPerDay
        self.dismissalWeight = dismissalWeight
    }

    public static let defaultIntervals: [Importance: TimeInterval] = [
        .low: TimeSpan.hours(4),
        .normal: TimeSpan.hours(2),
        .high: TimeSpan.minutes(30),
        .critical: TimeSpan.minutes(15),
    ]

    public static let `default` = FollowUpTiming()

    // MARK: Decisions

    /// How long to wait before the next attempt.
    ///
    /// Three inputs, applied in order: how much the task matters, how many
    /// attempts have already failed, and how much time is actually left.
    /// Deadline proximity wins — an interval that lands after the deadline is
    /// not a reminder, it is an obituary.
    public func delay(
        importance: Importance,
        attempt: Int,
        deadline: Date?,
        now: Date
    ) -> TimeInterval {
        let base = interval[importance] ?? interval[.normal] ?? TimeSpan.hours(2)

        // Each failed attempt halves the wait, floored so this cannot run away.
        let tightened = base * pow(repeatedAttemptFactor, Double(max(0, attempt)))
        var chosen = max(minimumInterval, tightened)

        if let deadline {
            let remaining = deadline.timeIntervalSince(now)
            if remaining <= 0 {
                // Already overdue. Support continues — this is exactly when a
                // person most needs it — but at a steady pace rather than an
                // accelerating one.
                return max(minimumInterval, overdueInterval)
            }
            if chosen > remaining * deadlineFraction {
                chosen = max(minimumInterval, remaining * deadlineFraction)
            }
        }

        return chosen
    }

    /// How loudly to deliver the next attempt.
    ///
    /// Escalation climbs with both importance and repeated failure, and stops
    /// at `.alarm`. It never bypasses the user: a plan whose snooze policy or
    /// completion policy says otherwise still governs, and quiet hours are
    /// still applied downstream by `ReminderScheduleResolver`.
    public func escalation(
        importance: Importance,
        attempt: Int,
        base: EscalationLevel
    ) -> EscalationLevel {
        var level = base
        switch importance {
        case .low: level = .gentle
        case .normal: break
        case .high: level = level.escalated
        case .critical: level = .alarm
        }

        // One step per attempt after the first.
        for _ in 0..<max(0, attempt) {
            level = level.escalated
        }
        // The ceiling. Applied last so nothing above can route around it.
        return min(level, maximumEscalation)
    }

    /// How much pressure a task has already absorbed.
    ///
    /// The single number the escalation rules read, assembled from the four
    /// things the user actually did: reminders that went unanswered, reminders
    /// they dismissed, times they pushed it back, and follow-ups already spent.
    /// Section 26 lists these as separate inputs; collapsing them here — with
    /// dismissals weighted heavier than silence — keeps every call site from
    /// having to remember all four.
    ///
    /// Deliberately not a model call. This has to give the same answer offline,
    /// instantly, at three in the morning.
    public func pressure(for task: TaskItem) -> Int {
        task.followUpCount
            + task.missCount
            + task.snoozeCount
            + task.dismissalCount * max(1, dismissalWeight)
    }

    /// Whether this task has already had its share of interruptions today.
    ///
    /// Counted from stages the plan actually scheduled, so it survives a
    /// relaunch — a budget kept in memory would reset every time the app was
    /// killed, which is precisely when a storm would otherwise start.
    public func hasExhaustedDailyBudget(
        plan: ReminderPlan,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let dayStart = calendar.startOfDay(for: now)
        let scheduledToday = plan.stages.filter { stage in
            guard let scheduled = stage.scheduledFor else { return false }
            return scheduled >= dayStart && scheduled <= now.addingTimeInterval(TimeSpan.day)
        }
        return scheduledToday.count >= maximumInterventionsPerDay
    }

    /// Whether the next attempt should ask for confirmation rather than simply
    /// reminding. Repeated silence is the signal that a nudge is not enough.
    public func requiresConfirmation(attempt: Int, importance: Importance) -> Bool {
        attempt >= confirmationAfterAttempts || importance >= .high
    }
}
