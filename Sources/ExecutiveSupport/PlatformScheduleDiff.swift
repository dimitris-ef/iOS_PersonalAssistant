import AssistantDomain
import Foundation

/// One OS-backed request the app wants to exist.
///
/// Derived from a persisted stage, never stored (section 55). The whole point
/// is that the desired schedule is a *function* of domain state: if it were
/// stored, it would be a second source of truth that could go stale, and the
/// question "what should iOS be holding right now?" would have two answers.
public struct DesiredScheduleEntry: Hashable, Sendable {
    public var stageID: ReminderStage.ID
    public var taskID: TaskItem.ID
    public var planID: ReminderPlan.ID
    public var fireDate: Date
    public var channel: ReminderChannel
    public var title: String
    public var body: String
    public var escalation: EscalationLevel
    public var requiresConfirmation: Bool
    /// The plan revision this entry describes.
    public var revision: Int

    public init(
        stageID: ReminderStage.ID,
        taskID: TaskItem.ID,
        planID: ReminderPlan.ID,
        fireDate: Date,
        channel: ReminderChannel,
        title: String,
        body: String,
        escalation: EscalationLevel,
        requiresConfirmation: Bool,
        revision: Int
    ) {
        self.stageID = stageID
        self.taskID = taskID
        self.planID = planID
        self.fireDate = fireDate
        self.channel = channel
        self.title = title
        self.body = body
        self.escalation = escalation
        self.requiresConfirmation = requiresConfirmation
        self.revision = revision
    }

    /// What has to match for an existing OS request to still be correct.
    ///
    /// Time, loudness, channel and revision. Deliberately *not* the body text:
    /// a wording change is not worth tearing down and re-adding a notification,
    /// and doing so on every pass is how a reminder ends up briefly not
    /// scheduled at all.
    ///
    /// The date is compared to the second. Sub-second differences come from
    /// rounding a `Date` through the OS and back, and treating them as changes
    /// would make every pass rewrite every request.
    public func matches(_ existing: ExistingScheduleEntry) -> Bool {
        Int(fireDate.timeIntervalSince1970) == Int(existing.fireDate.timeIntervalSince1970)
            && escalation == existing.escalation
            && channel == existing.channel
            && revision == existing.revision
    }
}

/// One OS-backed request that currently exists.
///
/// Read back from `getPendingNotificationRequests` and the alarm service, and
/// filtered to the app's own (section 29 — nothing here can see, let alone
/// remove, a notification this app did not schedule).
public struct ExistingScheduleEntry: Hashable, Sendable {
    public var stageID: ReminderStage.ID
    public var fireDate: Date
    public var channel: ReminderChannel
    public var escalation: EscalationLevel
    /// The revision recorded when this request was created, when the app knows
    /// it. Nil for a request scheduled by a build that predates revisions,
    /// which is treated as "unknown, therefore replace".
    public var revision: Int?

    public init(
        stageID: ReminderStage.ID,
        fireDate: Date,
        channel: ReminderChannel,
        escalation: EscalationLevel,
        revision: Int? = nil
    ) {
        self.stageID = stageID
        self.fireDate = fireDate
        self.channel = channel
        self.escalation = escalation
        self.revision = revision
    }
}

/// The difference between what the app wants scheduled and what is scheduled.
///
/// ## Why a diff rather than "cancel everything and re-add"
///
/// Section 29 rules out `removeAllPendingNotificationRequests()`, and the
/// reasons are worth keeping next to the code:
///
/// - It removes notifications this app did not schedule. Other features, a
///   notification service extension, a future version — all of them gone.
/// - There is a window, however short, in which the user has *no* reminders
///   scheduled at all. If the app is terminated inside that window, support
///   silently stops until the next launch.
/// - It makes duplicate and stale detection impossible, because everything is
///   always both new and obsolete.
///
/// A diff instead: matching requests are left completely alone, so a
/// reconciliation pass over an unchanged store touches nothing at all. That is
/// what makes running it on every foreground cheap enough to actually do
/// (section 48).
public struct PlatformScheduleDiff: Hashable, Sendable {
    /// Requests to add — either missing, or replacing one that has moved.
    public var toSchedule: [DesiredScheduleEntry]
    /// Stage identifiers whose OS requests should be withdrawn.
    public var toCancel: [ReminderStage.ID]
    /// Already correct. Named rather than implied, because "we did nothing and
    /// that was right" is the outcome worth being able to assert.
    public var unchanged: [ReminderStage.ID]

    public init(
        toSchedule: [DesiredScheduleEntry] = [],
        toCancel: [ReminderStage.ID] = [],
        unchanged: [ReminderStage.ID] = []
    ) {
        self.toSchedule = toSchedule
        self.toCancel = toCancel
        self.unchanged = unchanged
    }

    public var isEmpty: Bool {
        toSchedule.isEmpty && toCancel.isEmpty
    }

    /// Computes the difference.
    ///
    /// Three outcomes per stage, and section 27 names all of them:
    ///
    /// - desired, not present → schedule
    /// - present, not desired → cancel
    /// - both, and equivalent → leave alone
    /// - both, and different → cancel *and* schedule, in that order
    ///
    /// The last case is why `toCancel` may contain a stage that also appears in
    /// `toSchedule`: a reminder that moved from 3:20 to 4:20 is one withdrawal
    /// followed by one addition, and doing them in the other order would leave
    /// two requests for a moment — or, with a stable identifier, would have the
    /// addition silently replaced by the cancellation.
    ///
    /// Deterministic: both sides are sorted, so the same inputs produce the
    /// same diff, which is what makes it testable and what makes a log of it
    /// comparable between runs.
    public static func between(
        desired: [DesiredScheduleEntry],
        existing: [ExistingScheduleEntry]
    ) -> PlatformScheduleDiff {
        let existingByStage = Dictionary(
            existing.map { ($0.stageID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let desiredIDs = Set(desired.map(\.stageID))

        var diff = PlatformScheduleDiff()

        for entry in desired.sorted(by: { $0.fireDate < $1.fireDate }) {
            guard let current = existingByStage[entry.stageID] else {
                diff.toSchedule.append(entry)
                continue
            }
            if entry.matches(current) {
                diff.unchanged.append(entry.stageID)
            } else {
                diff.toCancel.append(entry.stageID)
                diff.toSchedule.append(entry)
            }
        }

        // Anything iOS is holding that the domain no longer wants. This is the
        // path that cleans up after a completed task (section 57), a cancelled
        // routine (section 58), and a plan that was recalculated while the app
        // was not running.
        for entry in existing.sorted(by: { $0.fireDate < $1.fireDate })
        where !desiredIDs.contains(entry.stageID) {
            diff.toCancel.append(entry.stageID)
        }

        return diff
    }
}
