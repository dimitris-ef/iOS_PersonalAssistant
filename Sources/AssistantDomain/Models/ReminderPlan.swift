import Foundation

/// What a reminder plan is about.
public struct ReminderSubject: Hashable, Codable, Sendable {
    public enum Reference: Hashable, Codable, Sendable {
        case task(TaskItem.ID)
        case calendarItem(CalendarItem.ID)
        case freeform(String)
    }

    public var reference: Reference
    public var title: String
    public var anchor: ReminderAnchor
    public var importance: Importance
    public var preparationDuration: TimeInterval?
    public var travelDuration: TimeInterval?
    /// Fixed appointments get leave-time and final-call stages; flexible work
    /// gets nudges spread across its window instead.
    public var isTimeFixed: Bool

    public init(
        reference: Reference,
        title: String,
        anchor: ReminderAnchor,
        importance: Importance = .normal,
        preparationDuration: TimeInterval? = nil,
        travelDuration: TimeInterval? = nil,
        isTimeFixed: Bool = true
    ) {
        self.reference = reference
        self.title = title
        self.anchor = anchor
        self.importance = importance
        self.preparationDuration = preparationDuration
        self.travelDuration = travelDuration
        self.isTimeFixed = isTimeFixed
    }
}

public enum ReminderAnchor: Hashable, Codable, Sendable {
    /// A specific moment the reminders hang off.
    case moment(Date)
    /// A hard deadline with no fixed start.
    case deadline(Date)
    /// A span the work can happen in.
    case window(TimeWindow)
    case unscheduled

    public var date: Date? {
        switch self {
        case .moment(let date): return date
        case .deadline(let date): return date
        case .window(let window): return window.end
        case .unscheduled: return nil
        }
    }
}

public enum ReminderStageKind: String, Hashable, Codable, Sendable, CaseIterable {
    /// "Your haircut is in three days."
    case advanceNotice
    /// "You have a haircut today."
    case morningOf
    /// "Start getting ready."
    case preparation
    /// "You need to leave now."
    case leave
    /// "Starting in 10 minutes."
    case finalCall
    /// Delivered after the fact when the task was never confirmed complete.
    case followUp
    /// Free-form nudge for flexible work.
    case nudge
}

/// Where a stage fires, relative to the plan's anchor.
public enum ReminderOffset: Hashable, Codable, Sendable {
    case beforeAnchor(TimeInterval)
    case afterAnchor(TimeInterval)
    /// A given number of days before the anchor, at a specific time of day.
    case daysBefore(Int, at: TimeOfDay)
    /// The morning of the anchor day, at a specific time.
    case morningOf(TimeOfDay)
    case absolute(Date)
}

/// Which system delivers the stage.
public enum ReminderChannel: String, Hashable, Codable, Sendable, CaseIterable {
    case notification
    case alarm
    /// Written into the system reminders list rather than pushed.
    case reminderList
}

public struct ReminderStage: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<ReminderStage>

    public var id: ID
    public var kind: ReminderStageKind
    public var offset: ReminderOffset
    public var channel: ReminderChannel
    public var escalation: EscalationLevel
    public var message: String
    /// When true, the user must actively confirm; dismissing is not enough.
    public var requiresConfirmation: Bool

    public init(
        id: ID = ID(),
        kind: ReminderStageKind,
        offset: ReminderOffset,
        channel: ReminderChannel = .notification,
        escalation: EscalationLevel = .standard,
        message: String,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.offset = offset
        self.channel = channel
        self.escalation = escalation
        self.message = message
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct FollowUpPolicy: Hashable, Codable, Sendable {
    public var isEnabled: Bool
    public var maximumFollowUps: Int
    public var interval: TimeInterval
    public var escalatesEachTime: Bool

    public init(
        isEnabled: Bool = true,
        maximumFollowUps: Int = 3,
        interval: TimeInterval = Duration.hours(2),
        escalatesEachTime: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.maximumFollowUps = maximumFollowUps
        self.interval = interval
        self.escalatesEachTime = escalatesEachTime
    }

    public static let disabled = FollowUpPolicy(isEnabled: false, maximumFollowUps: 0)
}

public struct SnoozePolicy: Hashable, Codable, Sendable {
    public var isAllowed: Bool
    public var defaultDuration: TimeInterval
    public var maximumSnoozes: Int
    /// After this many snoozes, raise the escalation level.
    public var escalateAfterSnoozes: Int

    public init(
        isAllowed: Bool = true,
        defaultDuration: TimeInterval = Duration.minutes(10),
        maximumSnoozes: Int = 3,
        escalateAfterSnoozes: Int = 2
    ) {
        self.isAllowed = isAllowed
        self.defaultDuration = defaultDuration
        self.maximumSnoozes = maximumSnoozes
        self.escalateAfterSnoozes = escalateAfterSnoozes
    }
}

public struct CompletionPolicy: Hashable, Codable, Sendable {
    /// The core ADHD rule: dismissing a reminder is not completing the task.
    public var requiresExplicitConfirmation: Bool
    /// How long after the anchor an unconfirmed task is considered missed.
    public var markMissedAfter: TimeInterval?

    public init(
        requiresExplicitConfirmation: Bool = true,
        markMissedAfter: TimeInterval? = Duration.hours(1)
    ) {
        self.requiresExplicitConfirmation = requiresExplicitConfirmation
        self.markMissedAfter = markMissedAfter
    }
}

/// A generated set of reminder stages plus the policies governing them.
///
/// Plans are data, not code paths: a different planner can produce a completely
/// different shape for the same subject without anything downstream changing.
public struct ReminderPlan: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<ReminderPlan>

    public var id: ID
    public var subject: ReminderSubject
    public var stages: [ReminderStage]
    public var followUp: FollowUpPolicy
    public var snooze: SnoozePolicy
    public var completion: CompletionPolicy
    public var createdAt: Date
    /// Identifier of the planner that produced this, so we can evolve
    /// strategies and still understand plans generated by older versions.
    public var generatedBy: String

    public init(
        id: ID = ID(),
        subject: ReminderSubject,
        stages: [ReminderStage],
        followUp: FollowUpPolicy = FollowUpPolicy(),
        snooze: SnoozePolicy = SnoozePolicy(),
        completion: CompletionPolicy = CompletionPolicy(),
        createdAt: Date,
        generatedBy: String
    ) {
        self.id = id
        self.subject = subject
        self.stages = stages
        self.followUp = followUp
        self.snooze = snooze
        self.completion = completion
        self.createdAt = createdAt
        self.generatedBy = generatedBy
    }
}

/// A stage resolved to a concrete moment, ready to hand to a platform service.
public struct ScheduledReminder: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<ScheduledReminder>

    public var id: ID
    public var planID: ReminderPlan.ID
    public var stageID: ReminderStage.ID
    public var kind: ReminderStageKind
    public var fireDate: Date
    public var channel: ReminderChannel
    public var title: String
    public var body: String
    public var escalation: EscalationLevel
    public var requiresConfirmation: Bool

    public init(
        id: ID = ID(),
        planID: ReminderPlan.ID,
        stageID: ReminderStage.ID,
        kind: ReminderStageKind,
        fireDate: Date,
        channel: ReminderChannel,
        title: String,
        body: String,
        escalation: EscalationLevel,
        requiresConfirmation: Bool
    ) {
        self.id = id
        self.planID = planID
        self.stageID = stageID
        self.kind = kind
        self.fireDate = fireDate
        self.channel = channel
        self.title = title
        self.body = body
        self.escalation = escalation
        self.requiresConfirmation = requiresConfirmation
    }
}

/// Things that happen to a reminder or task, feeding the status machine.
public enum EngagementEvent: Hashable, Codable, Sendable {
    case reminderDelivered(at: Date)
    /// The user swiped it away. Deliberately *not* completion.
    case reminderDismissed(at: Date)
    case snoozed(until: Date)
    case startedWorking(at: Date)
    case confirmedComplete(at: Date)
    case deferred(to: Date)
    case anchorPassed(at: Date)
    case cancelled(at: Date)
}
