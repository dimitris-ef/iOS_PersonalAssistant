import Foundation

/// Where a task stands.
///
/// This intentionally models engagement, not just completion. Dismissing a
/// notification moves a task out of `notStarted`, but it does **not** move it to
/// `completed` — that distinction is the point of the whole ADHD support layer.
public enum TaskStatus: String, Hashable, Codable, Sendable, CaseIterable {
    case notStarted
    /// A reminder was delivered and the user saw or dismissed it.
    case reminded
    case snoozed
    case inProgress
    case completed
    /// The moment passed without confirmation.
    case missed
    /// Still open and the assistant should come back to it.
    case needsFollowUp
    case cancelled
    /// Its window closed. Nobody did it and nobody can now.
    ///
    /// The state a 10 AM meeting reaches at 4 PM. Distinct from `missed`, which
    /// still expects recovery, and distinct from `cancelled`, which is a
    /// decision someone made. Support stops — continuing to ask about an
    /// occurrence that cannot happen is the behaviour that teaches people to
    /// ignore the app — but nothing claims it was done.
    case expired
    /// The user said "not this time".
    ///
    /// Only reachable for a recurring occurrence, and deliberately not
    /// `cancelled`: skipping today's gym session is not cancelling the gym.
    case skipped

    /// True once nothing further will be scheduled for this task.
    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .expired, .skipped:
            return true
        case .notStarted, .reminded, .snoozed, .inProgress, .missed, .needsFollowUp:
            return false
        }
    }

    /// True when the assistant is still responsible for chasing this task.
    public var isOutstanding: Bool { !isTerminal }

    /// True once this task can no longer block anything downstream.
    ///
    /// Wider than "done" on purpose. A prerequisite that was skipped or has
    /// expired is never going to be completed, and leaving its dependents
    /// blocked forever would turn one missed step into a permanently stuck
    /// list.
    public var isSettled: Bool { isTerminal }

    /// Whether this counts as the work actually having happened.
    ///
    /// The distinction the whole product rests on, in one property: four
    /// statuses end support and exactly one of them means success.
    public var isSuccess: Bool { self == .completed }
}

/// String-backed so it survives the JSON round trip through an AI provider
/// unambiguously; `rank` carries the ordering.
public enum Importance: String, Hashable, Codable, Sendable, Comparable, CaseIterable {
    case low
    case normal
    case high
    case critical

    public var rank: Int {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: Importance, rhs: Importance) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// How firmly a task is pinned to a moment in time.
public enum TimingPreference: Hashable, Codable, Sendable {
    /// "Sunday at 10 PM" — a fixed appointment.
    case fixed(Date)
    /// "sometime this week" — anywhere in the window.
    case flexible(TimeWindow)
    /// "before Friday" — no start, hard end.
    case dueBy(Date)
    /// No time attached yet.
    case unscheduled

    /// The instant the task is anchored to, when there is one.
    public var anchorDate: Date? {
        switch self {
        case .fixed(let date): return date
        case .dueBy(let date): return date
        case .flexible(let window): return window.end
        case .unscheduled: return nil
        }
    }

    public var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }
}

/// Something the user needs to do.
///
/// Also one occurrence of something they do repeatedly. A recurring
/// responsibility is a ``Routine``; each of its occurrences is one of these,
/// carrying `routineID` and `occurrenceDate`. That is deliberate and it is the
/// whole reason recurrence did not need a second lifecycle: this morning's
/// medication gets the same status machine, the same reminder plan, the same
/// escalation and the same place in the Today list as anything else.
public struct TaskItem: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<TaskItem>

    public var id: ID
    public var title: String
    public var details: String?
    public var status: TaskStatus
    public var importance: Importance
    public var timing: TimingPreference
    public var deadline: Date?
    public var preparationDuration: TimeInterval?
    public var travelDuration: TimeInterval?
    /// Roughly how long the work itself takes, once started.
    ///
    /// Distinct from `preparationDuration`, which is what happens *before*. Used
    /// by ranking to prefer something achievable in the gap that is actually
    /// left.
    public var estimatedDuration: TimeInterval?
    /// The recurring responsibility this is an occurrence of, when it is one.
    public var routineID: Routine.ID?
    /// Which occurrence. The scheduled moment, not when it was created.
    public var occurrenceDate: Date?
    /// Tasks that must be settled before this one is worth doing.
    ///
    /// Stored on the dependent rather than in a separate edge table, because
    /// the question asked constantly — "am I blocked?" — is then answerable
    /// from the task in hand. ``TaskDependencyGraph`` handles the questions
    /// that genuinely need more than one task.
    public var dependsOn: [TaskItem.ID]
    /// The ordered things to do before this can happen.
    public var preparationSteps: [PreparationStep]
    public var linkedCalendarItemID: CalendarItem.ID?
    public var reminderPlanID: ReminderPlan.ID?
    /// How many times the assistant has already chased this task.
    public var followUpCount: Int
    public var snoozeCount: Int
    /// How many reminders were swiped away without resolving anything.
    ///
    /// Counted separately from misses because they mean different things: a
    /// dismissal is a person who saw it and chose not to act, a miss is one who
    /// never saw it. The first calls for a different approach, the second for a
    /// louder one.
    public var dismissalCount: Int
    /// How many reminders went entirely unanswered.
    public var missCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: ID = ID(),
        title: String,
        details: String? = nil,
        status: TaskStatus = .notStarted,
        importance: Importance = .normal,
        timing: TimingPreference = .unscheduled,
        deadline: Date? = nil,
        preparationDuration: TimeInterval? = nil,
        travelDuration: TimeInterval? = nil,
        estimatedDuration: TimeInterval? = nil,
        routineID: Routine.ID? = nil,
        occurrenceDate: Date? = nil,
        dependsOn: [TaskItem.ID] = [],
        preparationSteps: [PreparationStep] = [],
        linkedCalendarItemID: CalendarItem.ID? = nil,
        reminderPlanID: ReminderPlan.ID? = nil,
        followUpCount: Int = 0,
        snoozeCount: Int = 0,
        dismissalCount: Int = 0,
        missCount: Int = 0,
        createdAt: Date,
        updatedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.importance = importance
        self.timing = timing
        self.deadline = deadline
        self.preparationDuration = preparationDuration
        self.travelDuration = travelDuration
        self.estimatedDuration = estimatedDuration
        self.routineID = routineID
        self.occurrenceDate = occurrenceDate
        self.dependsOn = dependsOn
        self.preparationSteps = preparationSteps
        self.linkedCalendarItemID = linkedCalendarItemID
        self.reminderPlanID = reminderPlanID
        self.followUpCount = followUpCount
        self.snoozeCount = snoozeCount
        self.dismissalCount = dismissalCount
        self.missCount = missCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
    }

    /// True when this is one occurrence of a recurring responsibility.
    public var isRoutineOccurrence: Bool { routineID != nil }

    /// The moment this task is anchored to, however it was expressed.
    public var anchorDate: Date? {
        occurrenceDate ?? timing.anchorDate ?? deadline
    }
}

/// Filter used when asking the task repository for a subset of tasks.
public struct TaskFilter: Hashable, Sendable {
    public var statuses: Set<TaskStatus>
    public var window: TimeWindow?
    public var minimumImportance: Importance?
    public var limit: Int?
    /// Occurrences of one recurring responsibility.
    public var routineID: Routine.ID?

    public init(
        statuses: Set<TaskStatus> = [],
        window: TimeWindow? = nil,
        minimumImportance: Importance? = nil,
        limit: Int? = nil,
        routineID: Routine.ID? = nil
    ) {
        self.statuses = statuses
        self.window = window
        self.minimumImportance = minimumImportance
        self.limit = limit
        self.routineID = routineID
    }

    public static let outstanding = TaskFilter(
        statuses: Set(TaskStatus.allCases.filter(\.isOutstanding))
    )

    public func matches(_ task: TaskItem) -> Bool {
        if !statuses.isEmpty && !statuses.contains(task.status) { return false }
        if let minimumImportance, task.importance < minimumImportance { return false }
        if let window {
            guard let anchor = task.anchorDate else { return false }
            guard window.contains(anchor) else { return false }
        }
        if let routineID, task.routineID != routineID { return false }
        return true
    }
}
