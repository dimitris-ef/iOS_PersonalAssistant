import AssistantDomain
import Foundation

/// The result of applying an engagement event to a task.
public struct StatusTransition: Hashable, Sendable {
    public var status: TaskStatus
    public var snoozeCount: Int
    public var followUpCount: Int
    /// Reminders swiped away without resolving anything.
    public var dismissalCount: Int
    /// Reminders that went entirely unanswered.
    public var missCount: Int
    /// Raised escalation for the next reminder, when the transition warrants it.
    public var nextEscalation: EscalationLevel?
    /// When the assistant should check back, if it should.
    public var followUpAt: Date?

    public init(
        status: TaskStatus,
        snoozeCount: Int,
        followUpCount: Int,
        dismissalCount: Int = 0,
        missCount: Int = 0,
        nextEscalation: EscalationLevel? = nil,
        followUpAt: Date? = nil
    ) {
        self.status = status
        self.snoozeCount = snoozeCount
        self.followUpCount = followUpCount
        self.dismissalCount = dismissalCount
        self.missCount = missCount
        self.nextEscalation = nextEscalation
        self.followUpAt = followUpAt
    }
}

/// Decides what an engagement event means for a task.
///
/// This is the heart of the executive-function support: **dismissing a reminder
/// is not completing a task**. A dismissal moves a task to `reminded` (or
/// `needsFollowUp` when confirmation is required), and the assistant keeps
/// responsibility for it. Only an explicit confirmation completes it.
///
/// Pure and synchronous, so every rule here is directly testable.
public struct TaskStatusMachine: Sendable {
    public init() {}

    public func apply(
        _ event: EngagementEvent,
        to task: TaskItem,
        plan: ReminderPlan?
    ) -> StatusTransition {
        let snooze = plan?.snooze ?? SnoozePolicy()
        let followUp = plan?.followUp ?? FollowUpPolicy()
        let completion = plan?.completion ?? CompletionPolicy()

        var snoozeCount = task.snoozeCount
        var followUpCount = task.followUpCount
        var dismissalCount = task.dismissalCount
        var missCount = task.missCount

        switch event {
        case .reminderDelivered:
            guard !task.status.isTerminal else { return unchanged(task) }
            return StatusTransition(
                status: task.status == .inProgress ? .inProgress : .reminded,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount
            )

        case .reminderDismissed(let date):
            guard !task.status.isTerminal else { return unchanged(task) }
            // The important rule. A swipe is acknowledgement, not completion.
            //
            // Counted before the policy guards, because the count is a fact
            // about what the user did and stays true whether or not the plan
            // has follow-ups left to spend on it.
            dismissalCount += 1
            guard completion.requiresExplicitConfirmation else {
                return StatusTransition(
                    status: .reminded,
                    snoozeCount: snoozeCount,
                    followUpCount: followUpCount,
                    dismissalCount: dismissalCount,
                    missCount: missCount
                )
            }
            guard followUp.isEnabled, followUpCount < followUp.maximumFollowUps else {
                return StatusTransition(
                    status: .reminded,
                    snoozeCount: snoozeCount,
                    followUpCount: followUpCount,
                    dismissalCount: dismissalCount,
                    missCount: missCount
                )
            }
            followUpCount += 1
            return StatusTransition(
                status: .needsFollowUp,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount,
                nextEscalation: followUp.escalatesEachTime ? escalated(task, plan: plan) : nil,
                followUpAt: date.addingTimeInterval(followUp.interval)
            )

        case .reminderMissed(let date):
            guard !task.status.isTerminal else { return unchanged(task) }
            missCount += 1
            // An unanswered reminder is not a failed task — the deadline may
            // still be days away. It *is* evidence that this intervention did
            // not work, so the assistant takes another turn rather than
            // quietly dropping it.
            guard followUp.isEnabled, followUpCount < followUp.maximumFollowUps else {
                // Out of follow-ups. The task stays outstanding rather than
                // moving to a terminal state: the app has stopped chasing, it
                // has not decided the work is done.
                return StatusTransition(
                    status: .needsFollowUp,
                    snoozeCount: snoozeCount,
                    followUpCount: followUpCount,
                    dismissalCount: dismissalCount,
                    missCount: missCount
                )
            }
            followUpCount += 1
            return StatusTransition(
                status: .needsFollowUp,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount,
                nextEscalation: escalated(task, plan: plan),
                followUpAt: date.addingTimeInterval(followUp.interval)
            )

        case .snoozed(let until):
            guard !task.status.isTerminal else { return unchanged(task) }
            guard snooze.isAllowed, snoozeCount < snooze.maximumSnoozes else {
                // Out of snoozes: stop letting it slide, escalate instead.
                return StatusTransition(
                    status: .needsFollowUp,
                    snoozeCount: snoozeCount,
                    followUpCount: followUpCount,
                    dismissalCount: dismissalCount,
                    missCount: missCount,
                    nextEscalation: .alarm,
                    followUpAt: until
                )
            }
            snoozeCount += 1
            let shouldEscalate = snoozeCount >= snooze.escalateAfterSnoozes
            return StatusTransition(
                status: .snoozed,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount,
                nextEscalation: shouldEscalate ? escalated(task, plan: plan) : nil,
                followUpAt: until
            )

        case .startedWorking:
            guard !task.status.isTerminal else { return unchanged(task) }
            return StatusTransition(
                status: .inProgress,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount
            )

        case .confirmedComplete:
            return StatusTransition(
                status: .completed,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount
            )

        case .deferred(let date):
            guard !task.status.isTerminal else { return unchanged(task) }
            return StatusTransition(
                status: .needsFollowUp,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount,
                followUpAt: date
            )

        case .anchorPassed(let date):
            guard !task.status.isTerminal else { return unchanged(task) }
            if task.status == .completed { return unchanged(task) }
            // Nothing was confirmed by the time the moment arrived.
            let shouldFollowUp = followUp.isEnabled && followUpCount < followUp.maximumFollowUps
            if shouldFollowUp {
                followUpCount += 1
            }
            return StatusTransition(
                status: .missed,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount,
                nextEscalation: shouldFollowUp ? escalated(task, plan: plan) : nil,
                followUpAt: shouldFollowUp ? date.addingTimeInterval(followUp.interval) : nil
            )

        case .cancelled:
            return StatusTransition(
                status: .cancelled,
                snoozeCount: snoozeCount,
                followUpCount: followUpCount,
                dismissalCount: dismissalCount,
                missCount: missCount
            )
        }
    }

    /// Applies a transition to a task, producing the updated value.
    public func updated(_ task: TaskItem, with transition: StatusTransition, at date: Date) -> TaskItem {
        var updated = task
        updated.status = transition.status
        updated.snoozeCount = transition.snoozeCount
        updated.followUpCount = transition.followUpCount
        updated.dismissalCount = transition.dismissalCount
        updated.missCount = transition.missCount
        updated.updatedAt = date
        if transition.status == .completed {
            updated.completedAt = date
        }
        return updated
    }

    private func unchanged(_ task: TaskItem) -> StatusTransition {
        StatusTransition(
            status: task.status,
            snoozeCount: task.snoozeCount,
            followUpCount: task.followUpCount,
            dismissalCount: task.dismissalCount,
            missCount: task.missCount
        )
    }

    private func escalated(_ task: TaskItem, plan: ReminderPlan?) -> EscalationLevel {
        let current = plan?.stages.map(\.escalation).max() ?? .standard
        return task.importance >= .high ? .alarm : current.escalated
    }
}
