import Foundation

/// How long a missed occurrence is still worth doing, and what happens when it
/// stops being worth doing.
///
/// ## The judgement this encodes
///
/// Missing the bins on Thursday night is recoverable on Friday morning; missing
/// a 10 AM meeting is not recoverable at 4 PM. Both are "the reminder did not
/// work", and treating them the same produces one of two failures: nagging
/// someone at 4 PM about a meeting that finished, or silently dropping a
/// medication dose that could still be taken at 10.
///
/// So the routine says how long its own recovery window is. Nothing here is
/// decided by a model — a policy that changed its mind between launches would
/// make the assistant's behaviour impossible to trust.
public struct RoutineRecoveryPolicy: Hashable, Codable, Sendable {
    /// Whether a missed occurrence is chased at all.
    public var isEnabled: Bool
    /// How long after the scheduled time doing it late is still useful.
    public var window: TimeInterval
    /// Whether the window may run past midnight into the following day.
    ///
    /// Separate from `window` because "still useful tomorrow morning" and "still
    /// useful for twelve hours" are different claims, and the bins are the case
    /// that shows it: Thursday 8 PM plus twelve hours is 8 AM Friday, which is
    /// right, while the same twelve hours on a 9 AM medication reaches 9 PM,
    /// which is not.
    public var allowsNextDay: Bool

    public init(
        isEnabled: Bool = true,
        window: TimeInterval = TimeSpan.hours(4),
        allowsNextDay: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.window = window
        self.allowsNextDay = allowsNextDay
    }

    /// Nothing is chased. For routines where being late is worse than skipping.
    public static let none = RoutineRecoveryPolicy(isEnabled: false, window: 0)

    /// The last moment a recovery attempt is still worth making.
    public func deadline(after scheduled: Date, calendar: Calendar) -> Date {
        guard isEnabled else { return scheduled }
        let byWindow = scheduled.addingTimeInterval(window)
        guard allowsNextDay else { return byWindow }

        // The end of the following day, so an evening routine stays recoverable
        // through the next morning however short the raw window is.
        let nextDay = calendar.date(byAdding: .day, value: 1, to: scheduled) ?? scheduled
        let endOfNextDay = calendar.startOfDay(for: nextDay).addingTimeInterval(TimeSpan.day - 1)
        return max(byWindow, endOfNextDay)
    }
}

/// A responsibility that comes round again.
///
/// ## Routine versus occurrence
///
/// This is the *definition* — "take medication every morning at nine". It is
/// never completed, never missed and never in progress, because those are
/// things that happen to a particular morning. Each occurrence is an ordinary
/// ``TaskItem`` carrying `routineID` and `occurrenceDate`, which is what lets
/// the whole existing lifecycle apply to it unchanged: the status machine, the
/// reminder plan, follow-up, escalation, the Today list.
///
/// The alternative — one task that is reset by hand every morning — is the
/// design this type exists to prevent. It loses the history, it cannot express
/// "yesterday's dose was missed but today's is done", and completing it once
/// ends the routine forever.
public struct Routine: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<Routine>

    public var id: ID
    public var title: String
    public var details: String?
    public var recurrence: RecurrenceRule
    public var importance: Importance
    /// False when the user has paused or ended it. Occurrences stop being
    /// generated; existing ones keep their own lifecycle.
    public var isActive: Bool
    public var recovery: RoutineRecoveryPolicy
    /// Carried onto every occurrence, so a routine with a journey attached
    /// produces leave-time support without restating it each time.
    public var preparationDuration: TimeInterval?
    public var travelDuration: TimeInterval?
    /// Steps every occurrence starts with. Copied, not shared: completing
    /// Tuesday's "pack kit" must not tick Thursday's.
    public var preparationSteps: [PreparationStep]
    public var lastCompletedAt: Date?
    public var lastMissedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        title: String,
        details: String? = nil,
        recurrence: RecurrenceRule,
        importance: Importance = .normal,
        isActive: Bool = true,
        recovery: RoutineRecoveryPolicy = RoutineRecoveryPolicy(),
        preparationDuration: TimeInterval? = nil,
        travelDuration: TimeInterval? = nil,
        preparationSteps: [PreparationStep] = [],
        lastCompletedAt: Date? = nil,
        lastMissedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.recurrence = recurrence
        self.importance = importance
        self.isActive = isActive
        self.recovery = recovery
        self.preparationDuration = preparationDuration
        self.travelDuration = travelDuration
        self.preparationSteps = preparationSteps
        self.lastCompletedAt = lastCompletedAt
        self.lastMissedAt = lastMissedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// The identity an occurrence at this moment must have.
    ///
    /// Derived rather than allocated, so working out that Thursday needs an
    /// occurrence twice produces one occurrence. See
    /// ``Identifier/deterministic(namespace:name:)``.
    ///
    /// The name is the occurrence's exact instant in seconds since the epoch —
    /// not a formatted date, which would drag a locale and a time zone into a
    /// primary key.
    public func occurrenceID(at date: Date) -> TaskItem.ID {
        TaskItem.ID.deterministic(
            namespace: "routine-occurrence/\(id.rawValue.uuidString)",
            name: String(Int(date.timeIntervalSince1970.rounded()))
        )
    }
}
