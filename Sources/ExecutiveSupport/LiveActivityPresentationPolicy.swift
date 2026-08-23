import AssistantDomain
import Foundation

/// Why a task deserves to be on the Lock Screen right now.
///
/// Deliberately an enum rather than a score. The reason is what the
/// presentation renders — "Leave soon" and "In progress" are different things
/// to look at — and a number would have to be turned back into one of these
/// anyway, in a second place, using a second set of thresholds.
public enum LiveActivityReason: String, Hashable, Sendable, CaseIterable {
    /// A preparation timeline is running: steps to do before leaving.
    case preparing
    /// Prepared, and the leave time is close.
    case leaving
    /// The user asked for help starting, and started.
    case startSession
    /// High importance, fixed time, close enough to matter.
    case deadline
    /// A routine occurrence inside its window.
    case routineWindow
}

/// One task the system should be showing.
public struct LiveActivityCandidate: Hashable, Sendable, Identifiable {
    public var id: TaskItem.ID { taskID }
    public var taskID: TaskItem.ID
    public var reason: LiveActivityReason
    /// The moment being counted towards — leave time, or the event itself.
    public var targetDate: Date?
    /// What the person should do next, when there is a step for it.
    public var nextStep: PreparationStep?
    public var completedSteps: Int
    public var totalSteps: Int
    /// How pressing this is against the others. Higher wins; used only to
    /// choose between candidates when there are more than the policy allows.
    public var urgency: Int

    public init(
        taskID: TaskItem.ID,
        reason: LiveActivityReason,
        targetDate: Date? = nil,
        nextStep: PreparationStep? = nil,
        completedSteps: Int = 0,
        totalSteps: Int = 0,
        urgency: Int = 0
    ) {
        self.taskID = taskID
        self.reason = reason
        self.targetDate = targetDate
        self.nextStep = nextStep
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.urgency = urgency
    }
}

/// Decides which tasks are worth a Live Activity, and which are not.
///
/// ## Why this is a policy object and not a judgement call in the UI
///
/// Section 90 asks for a deterministic rule and says explicitly not to ask a
/// model. Both halves matter. Deterministic, because a Live Activity that
/// appears for one appointment and not the identical one tomorrow is worse than
/// none — the whole value is that the user learns to trust it. Not a model,
/// because this runs at launch, in a background refresh and after every task
/// change, none of which can wait on inference or assume a network.
///
/// ## Why so few qualify
///
/// Section 47: a Live Activity is the loudest non-alarm surface iOS has. It
/// occupies the Lock Screen and the Dynamic Island continuously. Starting one
/// for every task would make the phone unusable and would train the user to
/// dismiss them, which costs the feature exactly when it matters — the
/// appointment they were going to be late for.
///
/// So the bar is: something is *happening now*, it has a time, and being late
/// for it would be bad. Everything else is a notification's job.
public struct LiveActivityPresentationPolicy: Sendable {
    /// How long before a fixed-time task an activity may start.
    ///
    /// Two hours. Long enough to cover a preparation timeline that begins well
    /// ahead; short enough that a 9 AM appointment is not on the Lock Screen
    /// overnight.
    public var leadTime: TimeInterval
    /// How long after the moment an activity stays before it is stale.
    public var trailingGrace: TimeInterval
    /// The most that may run at once.
    ///
    /// Section 91. Two, because the honest number of things a person can be
    /// actively doing is one, and the second slot exists so that "leave for the
    /// dentist" and "the thing you started ten minutes ago" do not fight.
    public var maximumConcurrent: Int
    /// The importance below which a plain deadline does not qualify.
    ///
    /// A normal-importance task with a due time gets a notification. Only
    /// something the user marked important takes over the Lock Screen — with
    /// the exception of an active preparation or start session, which the user
    /// asked for by name.
    public var deadlineImportanceFloor: Importance

    public init(
        leadTime: TimeInterval = TimeSpan.hours(2),
        trailingGrace: TimeInterval = TimeSpan.minutes(30),
        maximumConcurrent: Int = 2,
        deadlineImportanceFloor: Importance = .high
    ) {
        self.leadTime = max(TimeSpan.minutes(5), leadTime)
        self.trailingGrace = max(0, trailingGrace)
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.deadlineImportanceFloor = deadlineImportanceFloor
    }

    public static let `default` = LiveActivityPresentationPolicy()

    /// Whether one task qualifies, and why.
    ///
    /// Returns nil for the overwhelming majority of tasks, which is the
    /// intended outcome rather than a gap.
    public func candidate(
        for task: TaskItem,
        timeline: PreparationTimeline?,
        now: Date
    ) -> LiveActivityCandidate? {
        // A finished task is never showing. This is checked first and without
        // exception: an activity for something already done is the single most
        // corrosive thing this feature could do, because it says the assistant
        // does not know what the user just told it.
        guard !task.status.isTerminal else { return nil }

        // A preparation timeline that is running beats everything, whatever the
        // importance — the user is *doing this now*, which is the situation the
        // surface exists for.
        if let timeline, now >= timeline.startAt, now <= timeline.leaveAt.addingTimeInterval(trailingGrace) {
            let steps = timeline.keptSteps
            let done = steps.filter { $0.step.isCompleted }.count
            let leaving = now >= timeline.leaveAt.addingTimeInterval(-Self.leavingWindow)
            return LiveActivityCandidate(
                taskID: task.id,
                reason: leaving ? .leaving : .preparing,
                targetDate: timeline.leaveAt,
                nextStep: timeline.nextStep?.step,
                completedSteps: done,
                totalSteps: steps.count,
                urgency: leaving ? 900 : 800
            )
        }

        // "Help me start", accepted. `inProgress` is only ever reached by the
        // user saying so, which makes it the clearest signal available.
        if task.status == .inProgress {
            return LiveActivityCandidate(
                taskID: task.id,
                reason: .startSession,
                targetDate: task.anchorDate,
                nextStep: task.preparationSteps.nextIncomplete,
                completedSteps: task.preparationSteps.filter(\.isCompleted).count,
                totalSteps: task.preparationSteps.count,
                urgency: 700
            )
        }

        guard let anchor = task.anchorDate else { return nil }
        guard anchor >= now.addingTimeInterval(-trailingGrace) else { return nil }
        guard anchor <= now.addingTimeInterval(leadTime) else { return nil }

        if task.isRoutineOccurrence {
            return LiveActivityCandidate(
                taskID: task.id,
                reason: .routineWindow,
                targetDate: anchor,
                nextStep: task.preparationSteps.nextIncomplete,
                completedSteps: task.preparationSteps.filter(\.isCompleted).count,
                totalSteps: task.preparationSteps.count,
                urgency: 400
            )
        }

        guard task.importance >= deadlineImportanceFloor else { return nil }
        return LiveActivityCandidate(
            taskID: task.id,
            reason: .deadline,
            targetDate: anchor,
            urgency: 600
        )
    }

    /// The activities that should be running, in order.
    ///
    /// Bounded, and deterministically ordered: urgency, then how soon, then the
    /// identifier. The last tiebreak exists so two candidates that are equal in
    /// every meaningful way still produce the same answer on every pass —
    /// otherwise a reconciliation would swap them and the user would watch
    /// their Lock Screen flicker between two things for no reason.
    public func activities(
        for candidates: [LiveActivityCandidate]
    ) -> [LiveActivityCandidate] {
        candidates
            .sorted { first, second in
                if first.urgency != second.urgency { return first.urgency > second.urgency }
                let firstDate = first.targetDate ?? .distantFuture
                let secondDate = second.targetDate ?? .distantFuture
                if firstDate != secondDate { return firstDate < secondDate }
                return first.taskID.description < second.taskID.description
            }
            .prefix(maximumConcurrent)
            .map { $0 }
    }

    /// When an activity stops being worth showing whatever else happens.
    ///
    /// Handed to the system as a dismissal deadline, so an activity survives
    /// the app being terminated and still goes away by itself. Section 53: a
    /// stale Live Activity is not a small problem.
    public func staleDate(for candidate: LiveActivityCandidate, now: Date) -> Date {
        let base = candidate.targetDate ?? now.addingTimeInterval(TimeSpan.hours(1))
        return max(base, now).addingTimeInterval(trailingGrace)
    }

    /// How close to the leave time counts as "leaving".
    private static let leavingWindow = TimeSpan.minutes(15)
}
