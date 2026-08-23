import Foundation

/// How insistently a reminder should present itself.
///
/// This is a product-level concept. Each platform maps it onto its own
/// mechanism (notification interruption levels, critical alerts, alarms).
public enum EscalationLevel: String, Hashable, Codable, Sendable, Comparable, CaseIterable {
    /// Quiet — may be batched or delivered silently.
    case gentle
    /// A normal notification.
    case standard
    /// Breaks through Focus where the platform allows it.
    case insistent
    /// A real alarm: sound, repeats, requires dismissal.
    case alarm

    public var rank: Int {
        switch self {
        case .gentle: return 0
        case .standard: return 1
        case .insistent: return 2
        case .alarm: return 3
        }
    }

    public static func < (lhs: EscalationLevel, rhs: EscalationLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    /// One step more insistent, saturating at `.alarm`.
    public var escalated: EscalationLevel {
        switch self {
        case .gentle: return .standard
        case .standard: return .insistent
        case .insistent, .alarm: return .alarm
        }
    }
}

/// A notification the assistant wants delivered at a specific time.
public struct NotificationRequest: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<NotificationRequest>

    public var id: ID
    public var title: String
    public var body: String
    public var fireDate: Date
    public var escalation: EscalationLevel
    /// When true, dismissing this notification must not be treated as completion.
    public var requiresCompletionConfirmation: Bool
    public var relatedTaskID: TaskItem.ID?
    public var stageID: ReminderStage.ID?
    /// The plan revision this request was created from.
    ///
    /// Travels into the notification's `userInfo` and comes back with the
    /// user's answer. When it does not match the plan's current revision, the
    /// button they pressed belonged to a schedule that has since been replaced
    /// — a reminder for a time that moved, or a stage that was superseded — and
    /// the router declines it rather than resurrecting it.
    ///
    /// Optional because a request scheduled by a build that predates revisions
    /// has none, and a missing revision is treated as "cannot prove this is
    /// stale", not as "ignore it". Silently dropping every reminder in flight
    /// across an app update would be the worse failure.
    public var planRevision: Int?

    public init(
        id: ID = ID(),
        title: String,
        body: String,
        fireDate: Date,
        escalation: EscalationLevel = .standard,
        requiresCompletionConfirmation: Bool = true,
        relatedTaskID: TaskItem.ID? = nil,
        stageID: ReminderStage.ID? = nil,
        planRevision: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.escalation = escalation
        self.requiresCompletionConfirmation = requiresCompletionConfirmation
        self.relatedTaskID = relatedTaskID
        self.stageID = stageID
        self.planRevision = planRevision
    }
}

/// An alarm — the "make sure I actually wake up" case.
public struct AlarmRequest: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<AlarmRequest>

    public var id: ID
    public var label: String
    public var fireDate: Date
    public var allowsSnooze: Bool
    public var snoozeDuration: TimeInterval
    public var maximumSnoozes: Int
    public var recurrence: RecurrenceRule?
    public var relatedTaskID: TaskItem.ID?
    /// The plan revision this alarm was created from. See
    /// ``NotificationRequest/planRevision``.
    public var planRevision: Int?

    public init(
        id: ID = ID(),
        label: String,
        fireDate: Date,
        allowsSnooze: Bool = true,
        snoozeDuration: TimeInterval = TimeSpan.minutes(9),
        maximumSnoozes: Int = 3,
        recurrence: RecurrenceRule? = nil,
        relatedTaskID: TaskItem.ID? = nil,
        planRevision: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.fireDate = fireDate
        self.allowsSnooze = allowsSnooze
        self.snoozeDuration = snoozeDuration
        self.maximumSnoozes = maximumSnoozes
        self.recurrence = recurrence
        self.relatedTaskID = relatedTaskID
        self.planRevision = planRevision
    }
}

/// An entry in the system reminders list (distinct from our own task store —
/// this is the thing the user sees in Apple's Reminders app).
public struct ReminderItem: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<ReminderItem>

    public var id: ID
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var isCompleted: Bool
    public var listName: String?
    public var relatedTaskID: TaskItem.ID?
    public var externalIdentifier: String?

    public init(
        id: ID = ID(),
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        listName: String? = nil,
        relatedTaskID: TaskItem.ID? = nil,
        externalIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.listName = listName
        self.relatedTaskID = relatedTaskID
        self.externalIdentifier = externalIdentifier
    }
}
