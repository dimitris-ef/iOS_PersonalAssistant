import AssistantDomain
import Foundation

/// Context a planner needs beyond the subject itself.
public struct SupportPlanningContext: Sendable {
    public var profile: UserProfile
    public var preferences: SupportPreferences
    public var now: Date
    public var calendar: Calendar

    public init(profile: UserProfile, preferences: SupportPreferences, now: Date, calendar: Calendar) {
        self.profile = profile
        self.preferences = preferences
        self.now = now
        self.calendar = calendar
    }
}

/// What became of a reminder, from the planner's point of view.
///
/// Deliberately about the *reminder*. Whether the task is now finished is a
/// separate question, answered by `TaskStatusMachine`, and keeping the two
/// vocabularies apart is what stops "dismissed" quietly becoming "done".
public enum ReminderOutcome: Hashable, Sendable {
    /// It fired. Nothing has come back yet.
    case delivered
    /// The user asked for it again later. `until` is nil when they did not say
    /// when, in which case the plan's snooze policy decides.
    case snoozed(until: Date?)
    /// Swiped away without resolving anything.
    case dismissed
    /// The user said they are on it. Not completion.
    case acknowledged
    /// Its moment passed with no response.
    case missed
    /// The user confirmed the task is done.
    case completed
    /// The task was called off.
    case cancelled

    /// Whether this outcome resolves the task itself, as opposed to just this
    /// one reminder.
    public var resolvesTask: Bool {
        switch self {
        case .completed, .cancelled:
            return true
        case .delivered, .snoozed, .dismissed, .acknowledged, .missed:
            return false
        }
    }

    /// The reminder-lifecycle reading of an engagement event, when it has one.
    ///
    /// `nil` for events that say something about the task without saying
    /// anything about a reminder — `deferred` and `anchorPassed` are decisions
    /// about the work itself. Keeping the two vocabularies related but distinct
    /// is what lets one entry point serve both without conflating them.
    public init?(_ event: EngagementEvent) {
        switch event {
        case .reminderDelivered: self = .delivered
        case .reminderDismissed: self = .dismissed
        case .reminderMissed: self = .missed
        case .snoozed(let until): self = .snoozed(until: until)
        case .startedWorking: self = .acknowledged
        case .confirmedComplete: self = .completed
        case .cancelled: self = .cancelled
        case .deferred, .anchorPassed: return nil
        }
    }
}

/// The next thing the assistant should do about a task.
///
/// A single stage, not a schedule. Planning one step at a time keeps the plan
/// adaptive — the follow-up after a dismissal at 6 PM should depend on what
/// actually happened, not on a chain generated days earlier that no longer
/// reflects anything.
public struct SupportIntervention: Hashable, Sendable {
    public var stage: ReminderStage
    /// Why this exists, for the timeline and for anyone reading a log.
    public var rationale: String

    public init(stage: ReminderStage, rationale: String) {
        self.stage = stage
        self.rationale = rationale
    }
}

/// Turns "there is a thing at 10 PM on Sunday" into a staged reminder plan, and
/// decides what to do when a reminder does not land.
///
/// A protocol rather than a single implementation because the right strategy is
/// personal and will be learned over time: a planner that adapts to how often
/// the user actually snoozes, or one driven by an AI model, drops in here
/// without anything else changing.
public protocol SupportPlanner: Sendable {
    /// Stable identifier recorded on the plans this planner produces.
    var identifier: String { get }

    func makePlan(for subject: ReminderSubject, context: SupportPlanningContext) -> ReminderPlan

    /// What should happen next, given how the last reminder went.
    ///
    /// Returns `nil` when the assistant should stop — the task is resolved, the
    /// plan's follow-up budget is spent, or the outcome needs no reply. Nil
    /// means "nothing more to schedule", never "the task is finished"; those
    /// are different conclusions and only `TaskStatusMachine` draws the second.
    ///
    /// This is called after a domain event, never because a screen appeared.
    func nextIntervention(
        for task: TaskItem,
        plan: ReminderPlan,
        outcome: ReminderOutcome,
        context: SupportPlanningContext
    ) -> SupportIntervention?
}
