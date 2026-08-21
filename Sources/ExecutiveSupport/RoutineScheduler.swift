import AssistantDomain
import Foundation

/// What should happen to a routine occurrence whose moment has passed.
public enum RoutineRecoveryDecision: Hashable, Sendable {
    /// Still worth doing. `until` is the last moment that stays true.
    case recover(until: Date)
    /// The window has closed. Stop asking.
    case expire
    /// Nothing to decide — the occurrence is settled, or its time has not come.
    case none
}

/// Occurrence generation and missed-occurrence recovery.
///
/// ## What this is not
///
/// It is not a second planner. It works out *which* occurrences exist and
/// *whether a late one is still worth doing*, then hands ordinary
/// ``TaskItem``s to the ordinary machinery — `SupportPlanner` builds their
/// reminders, `TaskStatusMachine` runs their lifecycle, `FollowUpService`
/// chases them. Section 51's instruction, followed literally: recurrence needed
/// a helper, not a parallel universe.
///
/// Everything here is pure and takes its clock as an argument. No `Date()`, no
/// repository, no sleeping in tests.
public struct RoutineScheduler: Sendable {
    /// How far ahead occurrences are materialised.
    ///
    /// A rolling window rather than the whole future. "Every day at 9" over a
    /// year is 365 task records nobody has looked at, each with a reminder plan
    /// and a set of platform notifications, and iOS caps pending notifications
    /// at 64 anyway. Two days ahead is enough for tonight's and tomorrow's
    /// reminders to be scheduled before the app is next opened.
    public var horizon: TimeInterval
    /// A hard ceiling on how many occurrences one pass may create, whatever the
    /// window and the rule say between them.
    public var maximumPerPass: Int

    public init(
        horizon: TimeInterval = TimeSpan.days(2),
        maximumPerPass: Int = 16
    ) {
        self.horizon = horizon
        self.maximumPerPass = maximumPerPass
    }

    // MARK: Generation

    /// The occurrences that should exist but do not yet.
    ///
    /// Idempotent twice over. The scheduled instants come from the rule, so the
    /// same window always yields the same list; and each occurrence's id is
    /// derived from the routine and that instant, so an occurrence generated
    /// again is the *same record*, not a second one. Relaunching the app three
    /// times before breakfast produces one morning medication task.
    ///
    /// `existing` is what the store already holds for this routine. Anything
    /// already there — in any state, including completed and skipped — is left
    /// alone: regenerating a completed occurrence would quietly un-complete it.
    public func pendingOccurrences(
        for routine: Routine,
        existing: [TaskItem],
        now: Date,
        calendar: Calendar
    ) -> [TaskItem] {
        guard routine.isActive else { return [] }
        guard routine.recurrence.isValid else { return [] }

        let known = Set(existing.map(\.id))
        let window = TimeWindow(start: now, end: now.addingTimeInterval(horizon))
        let dates = routine.recurrence.occurrences(
            in: window,
            calendar: calendar,
            limit: maximumPerPass
        )

        return dates.compactMap { date in
            let id = routine.occurrenceID(at: date)
            guard !known.contains(id) else { return nil }
            return occurrence(of: routine, at: date, id: id, now: now)
        }
    }

    /// One occurrence, as an ordinary task.
    ///
    /// `.fixed` timing, because an occurrence *is* pinned to a moment — that is
    /// what makes the preparation and leave stages meaningful for a routine
    /// with a journey attached.
    public func occurrence(
        of routine: Routine,
        at date: Date,
        id: TaskItem.ID? = nil,
        now: Date
    ) -> TaskItem {
        TaskItem(
            id: id ?? routine.occurrenceID(at: date),
            title: routine.title,
            details: routine.details,
            status: .notStarted,
            importance: routine.importance,
            timing: .fixed(date),
            preparationDuration: routine.preparationDuration,
            travelDuration: routine.travelDuration,
            routineID: routine.id,
            occurrenceDate: date,
            // Copied, not shared. Ticking "pack kit" on Tuesday must leave
            // Thursday's untouched, and steps carry completion state.
            preparationSteps: routine.preparationSteps.map { step in
                var copy = step
                copy.id = PreparationStep.identity(
                    parent: "\(routine.id.rawValue.uuidString)/\(Int(date.timeIntervalSince1970.rounded()))",
                    title: step.title
                )
                copy.isCompleted = false
                copy.completedAt = nil
                copy.scheduledStart = nil
                return copy
            },
            createdAt: now
        )
    }

    // MARK: Recovery

    /// Whether a late occurrence is still worth chasing.
    ///
    /// The distinction section 8 asks for. Bins missed on Thursday night are
    /// worth a nudge on Friday morning; a meeting missed at 10 is not worth
    /// mentioning at 4. Both are "the reminder did not work", and the routine's
    /// own policy is what separates them.
    public func recoveryDecision(
        for occurrence: TaskItem,
        routine: Routine,
        now: Date,
        calendar: Calendar
    ) -> RoutineRecoveryDecision {
        // Settled is settled — including skipped, which is the user having
        // already answered this question.
        guard !occurrence.status.isTerminal else { return .none }
        guard let scheduled = occurrence.occurrenceDate else { return .none }
        guard now >= scheduled else { return .none }
        guard routine.recovery.isEnabled else { return .expire }

        let deadline = routine.recovery.deadline(after: scheduled, calendar: calendar)
        return now <= deadline ? .recover(until: deadline) : .expire
    }

    /// Applies a decision, returning the occurrence as it should now be stored.
    ///
    /// Expiry is a status change and nothing more: no completion time, no claim
    /// that anything happened. The routine itself is untouched — that is the
    /// point of section 11, and it falls out of the routine and the occurrence
    /// being different records rather than needing a rule to protect it.
    public func applying(
        _ decision: RoutineRecoveryDecision,
        to occurrence: TaskItem,
        at date: Date
    ) -> TaskItem {
        var updated = occurrence
        switch decision {
        case .expire:
            updated.status = .expired
            updated.updatedAt = date
        case .recover:
            // Left outstanding on purpose. `FollowUpService` owns what happens
            // next; this only says the window is still open.
            if updated.status == .notStarted {
                updated.status = .missed
                updated.updatedAt = date
            }
        case .none:
            break
        }
        return updated
    }

    /// One occurrence, skipped, without touching the routine.
    ///
    /// "Skip the gym today" resolves today and leaves Wednesday alone. Section
    /// 105 exists because the obvious implementation — cancel the task — would
    /// read to every other part of the system as cancelling the responsibility.
    public func skipping(_ occurrence: TaskItem, at date: Date) -> TaskItem {
        var updated = occurrence
        updated.status = .skipped
        updated.updatedAt = date
        return updated
    }

    /// The routine after one of its occurrences resolved.
    ///
    /// Records when it last went well and when it last did not, which is what
    /// escalation and the routine detail view read. The routine never becomes
    /// complete or cancelled here: an occurrence resolving says nothing about
    /// the responsibility continuing.
    public func routine(_ routine: Routine, after occurrence: TaskItem, at date: Date) -> Routine {
        var updated = routine
        switch occurrence.status {
        case .completed:
            updated.lastCompletedAt = occurrence.completedAt ?? date
        case .missed, .expired:
            updated.lastMissedAt = occurrence.occurrenceDate ?? date
        case .notStarted, .reminded, .snoozed, .inProgress, .needsFollowUp, .cancelled, .skipped:
            return routine
        }
        updated.updatedAt = date
        return updated
    }
}
