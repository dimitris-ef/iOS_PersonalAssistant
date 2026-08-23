import Foundation

/// How insistently a surface should present an item.
///
/// A deliberately small vocabulary. The main app decided this from the ranker,
/// the status machine and the support planner; a widget's job is to pick a
/// colour and a word for it, not to re-derive it.
public enum SurfaceEmphasis: String, Codable, Sendable, CaseIterable {
    case none
    case upNext
    case blocked
    case recovery
    case startNow
    case behind
}

/// What kind of thing an item is, in the small number of shapes a glanceable
/// surface can usefully distinguish.
public enum SurfaceItemKind: String, Codable, Sendable, CaseIterable {
    case task
    case event
    case preparation
    case leave
    case reminder
    case routine
}

/// One row of the day, as a widget needs it.
///
/// Section 7, applied literally: an identifier to act on, a title to draw, a
/// time to show, and two enums the presentation reads. No notes, no memory
/// context, no reminder history, no rationale text, no provider anything.
public struct TodaySnapshotItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// The task this row acts on, when it is a task. Nil for calendar events,
    /// which the app does not own and a widget cannot complete.
    public var taskID: UUID?
    public var title: String
    public var date: Date
    public var kind: SurfaceItemKind
    public var emphasis: SurfaceEmphasis
    public var isDone: Bool
    /// One short line — "Waiting on: collect the forms". Already written by the
    /// domain; never assembled here.
    public var detail: String?
    /// True when the title should be withheld on a Lock Screen (section 43).
    public var isSensitive: Bool

    public init(
        id: String,
        taskID: UUID? = nil,
        title: String,
        date: Date,
        kind: SurfaceItemKind,
        emphasis: SurfaceEmphasis = .none,
        isDone: Bool = false,
        detail: String? = nil,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.date = date
        self.kind = kind
        self.emphasis = emphasis
        self.isDone = isDone
        self.detail = detail
        self.isSensitive = isSensitive
    }

    /// What to show where the screen may be visible to someone else.
    ///
    /// Section 42 and 43. The time survives — it is what makes the row useful
    /// at a glance — and the title does not.
    public var privacySafeTitle: String {
        isSensitive ? Self.redactedTitle : title
    }

    /// Deliberately generic, and deliberately not "Private" or "Hidden", which
    /// both advertise that there is something to hide.
    public static let redactedTitle = "Upcoming"
}

/// The day, ready to render.
public struct TodaySnapshot: SystemSurfaceSnapshot {
    public static let storageKey = "today-snapshot"

    public var snapshotVersion: Int
    public var generatedAt: Date
    public var validUntil: Date?
    /// Ahead of `generatedAt`, in time order, already trimmed.
    public var items: [TodaySnapshotItem]
    /// How many outstanding things there are in total, including the ones that
    /// did not fit. A Lock Screen widget with room for one line can still say
    /// "3 more".
    public var outstandingCount: Int

    public init(
        snapshotVersion: Int = TodaySnapshot.currentVersion,
        generatedAt: Date,
        validUntil: Date? = nil,
        items: [TodaySnapshotItem] = [],
        outstandingCount: Int = 0
    ) {
        self.snapshotVersion = snapshotVersion
        self.generatedAt = generatedAt
        self.validUntil = validUntil
        self.items = items
        self.outstandingCount = outstandingCount
    }

    /// The next thing that has not happened yet.
    public func next(at date: Date) -> TodaySnapshotItem? {
        items.first { !$0.isDone && $0.date >= date } ?? items.first { !$0.isDone }
    }

    /// What is left after `date`.
    public func upcoming(at date: Date) -> [TodaySnapshotItem] {
        items.filter { !$0.isDone && $0.date >= date }
    }

    /// An empty day, for a first launch or an unreadable file.
    public static func placeholder(at date: Date) -> TodaySnapshot {
        TodaySnapshot(generatedAt: date)
    }
}

/// The single most useful task right now.
///
/// Separate from `TodaySnapshot` because the widget that shows it is separate,
/// and because a `systemSmall` widget reading a whole day to display one row is
/// a decode it does not need to do on every timeline refresh.
public struct TaskWidgetSnapshot: SystemSurfaceSnapshot {
    public static let storageKey = "next-task-snapshot"

    public var snapshotVersion: Int
    public var generatedAt: Date
    public var validUntil: Date?
    /// Nil when nothing is actionable — which is a real and good state, not an
    /// error. "Nothing right now" is worth showing.
    public var task: TodaySnapshotItem?
    /// How many outstanding tasks there are, for the accessory families that
    /// have room for a number and not a title.
    public var outstandingCount: Int
    /// True when the highest-ranked task is waiting on something else.
    public var isBlocked: Bool

    public init(
        snapshotVersion: Int = TaskWidgetSnapshot.currentVersion,
        generatedAt: Date,
        validUntil: Date? = nil,
        task: TodaySnapshotItem? = nil,
        outstandingCount: Int = 0,
        isBlocked: Bool = false
    ) {
        self.snapshotVersion = snapshotVersion
        self.generatedAt = generatedAt
        self.validUntil = validUntil
        self.task = task
        self.outstandingCount = outstandingCount
        self.isBlocked = isBlocked
    }

    public static func placeholder(at date: Date) -> TaskWidgetSnapshot {
        TaskWidgetSnapshot(generatedAt: date)
    }
}

/// The next executive-support intervention.
///
/// "Leave at 9:20", "Start getting ready at 2:35", "Still open: pay the
/// electricity bill". Part 8 and Part 11 decided all of it; this carries the
/// answer.
public struct ReminderWidgetSnapshot: SystemSurfaceSnapshot {
    public static let storageKey = "support-snapshot"

    public var snapshotVersion: Int
    public var generatedAt: Date
    public var validUntil: Date?
    public var intervention: TodaySnapshotItem?
    /// The task the intervention is about, so a Done button knows what to act
    /// on without the widget looking anything up.
    public var taskID: UUID?
    /// How many reminders are waiting but could not be scheduled with iOS —
    /// notification permission is off. Surfaced as a small honest warning
    /// rather than pretending the reminder will arrive.
    public var undeliverableCount: Int

    public init(
        snapshotVersion: Int = ReminderWidgetSnapshot.currentVersion,
        generatedAt: Date,
        validUntil: Date? = nil,
        intervention: TodaySnapshotItem? = nil,
        taskID: UUID? = nil,
        undeliverableCount: Int = 0
    ) {
        self.snapshotVersion = snapshotVersion
        self.generatedAt = generatedAt
        self.validUntil = validUntil
        self.intervention = intervention
        self.taskID = taskID
        self.undeliverableCount = undeliverableCount
    }

    public static func placeholder(at date: Date) -> ReminderWidgetSnapshot {
        ReminderWidgetSnapshot(generatedAt: date)
    }
}
