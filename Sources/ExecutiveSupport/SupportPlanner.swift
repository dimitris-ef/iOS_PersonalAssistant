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

/// Turns "there is a thing at 10 PM on Sunday" into a staged reminder plan.
///
/// A protocol rather than a single implementation because the right strategy is
/// personal and will be learned over time: a planner that adapts to how often
/// the user actually snoozes, or one driven by an AI model, drops in here
/// without anything else changing.
public protocol SupportPlanner: Sendable {
    /// Stable identifier recorded on the plans this planner produces.
    var identifier: String { get }

    func makePlan(for subject: ReminderSubject, context: SupportPlanningContext) -> ReminderPlan
}
