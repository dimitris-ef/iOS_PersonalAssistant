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

    public var isTerminal: Bool {
        self == .completed || self == .cancelled
    }

    /// True when the assistant is still responsible for chasing this task.
    public var isOutstanding: Bool {
        switch self {
        case .notStarted, .reminded, .snoozed, .inProgress, .missed, .needsFollowUp:
            return true
        case .completed, .cancelled:
            return false
        }
    }
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

public enum RecurrenceRule: Hashable, Codable, Sendable {
    case daily(interval: Int)
    /// `weekdays` uses `Calendar`'s 1-based weekday numbering (1 = Sunday).
    case weekly(interval: Int, weekdays: [Int])
    case monthly(interval: Int, day: Int)
    case yearly(interval: Int)
}

/// Something the user needs to do.
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
    public var recurrence: RecurrenceRule?
    public var linkedCalendarItemID: CalendarItem.ID?
    public var reminderPlanID: ReminderPlan.ID?
    /// How many times the assistant has already chased this task.
    public var followUpCount: Int
    public var snoozeCount: Int
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
        recurrence: RecurrenceRule? = nil,
        linkedCalendarItemID: CalendarItem.ID? = nil,
        reminderPlanID: ReminderPlan.ID? = nil,
        followUpCount: Int = 0,
        snoozeCount: Int = 0,
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
        self.recurrence = recurrence
        self.linkedCalendarItemID = linkedCalendarItemID
        self.reminderPlanID = reminderPlanID
        self.followUpCount = followUpCount
        self.snoozeCount = snoozeCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
    }
}

/// Filter used when asking the task repository for a subset of tasks.
public struct TaskFilter: Hashable, Sendable {
    public var statuses: Set<TaskStatus>
    public var window: TimeWindow?
    public var minimumImportance: Importance?
    public var limit: Int?

    public init(
        statuses: Set<TaskStatus> = [],
        window: TimeWindow? = nil,
        minimumImportance: Importance? = nil,
        limit: Int? = nil
    ) {
        self.statuses = statuses
        self.window = window
        self.minimumImportance = minimumImportance
        self.limit = limit
    }

    public static let outstanding = TaskFilter(
        statuses: Set(TaskStatus.allCases.filter(\.isOutstanding))
    )

    public func matches(_ task: TaskItem) -> Bool {
        if !statuses.isEmpty && !statuses.contains(task.status) { return false }
        if let minimumImportance, task.importance < minimumImportance { return false }
        if let window {
            guard let anchor = task.timing.anchorDate ?? task.deadline else { return false }
            guard window.contains(anchor) else { return false }
        }
        return true
    }
}
