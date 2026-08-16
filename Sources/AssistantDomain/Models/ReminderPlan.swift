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

/// Where one reminder stands in its own life.
///
/// A stage used to be a pure template — "fire 20 minutes before" — with no
/// record of what became of it. That made the interesting question
/// unanswerable: *was this reminder delivered, and did the user do anything
/// about it?* Without that, support ended the moment a notification was posted.
///
/// The states are about the **reminder**, not the task. A dismissed reminder
/// and a completed task are different facts, and this enum exists partly to
/// keep them from being conflated.
public enum ReminderStageState: String, Hashable, Codable, Sendable, CaseIterable {
    /// Scheduled, not yet fired.
    case pending
    /// Fired. Nothing has come back from the user.
    case delivered
    /// The user engaged with it — "I'm on it" — without saying it is done.
    case acknowledged
    /// The user asked for it again later.
    case snoozed
    /// Swiped away. **Not** completion.
    case dismissed
    /// Its moment passed with no response at all.
    case missed
    /// The task was resolved, so this reminder will never fire.
    case cancelled

    /// True when this stage is still expected to fire.
    ///
    /// Only `pending` counts. Everything else has either happened or been
    /// called off, which is what makes "is there already a follow-up waiting?"
    /// a question with one answer.
    public var isPending: Bool { self == .pending }

    /// True once nothing further will come of this stage.
    ///
    /// A resolved stage cannot take another outcome — the basis of idempotent
    /// outcome processing.
    public var isResolved: Bool {
        switch self {
        case .pending, .delivered:
            return false
        case .acknowledged, .snoozed, .dismissed, .missed, .cancelled:
            return true
        }
    }
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

    /// What has become of this reminder.
    public var state: ReminderStageState
    /// When `state` last changed. The audit trail for a plan's history.
    public var stateChangedAt: Date?
    /// The concrete moment this stage is expected to fire.
    ///
    /// Template stages carry a relative `offset` and get their date from
    /// `ReminderScheduleResolver` against the plan's anchor. Follow-ups have no
    /// anchor to hang off — a task with no fixed time can still need chasing —
    /// so the date is recorded here. It is also what reconciliation reads to
    /// decide that a pending reminder is now overdue.
    public var scheduledFor: Date?

    public init(
        id: ID = ID(),
        kind: ReminderStageKind,
        offset: ReminderOffset,
        channel: ReminderChannel = .notification,
        escalation: EscalationLevel = .standard,
        message: String,
        requiresConfirmation: Bool = false,
        state: ReminderStageState = .pending,
        stateChangedAt: Date? = nil,
        scheduledFor: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.offset = offset
        self.channel = channel
        self.escalation = escalation
        self.message = message
        self.requiresConfirmation = requiresConfirmation
        self.state = state
        self.stateChangedAt = stateChangedAt
        self.scheduledFor = scheduledFor
    }

    /// Records an outcome, stamped with when it happened.
    public mutating func transition(to state: ReminderStageState, at date: Date) {
        self.state = state
        self.stateChangedAt = date
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
        interval: TimeInterval = TimeSpan.hours(2),
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
        defaultDuration: TimeInterval = TimeSpan.minutes(10),
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
        markMissedAfter: TimeInterval? = TimeSpan.hours(1)
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

    // MARK: Lifecycle

    public var pendingStages: [ReminderStage] {
        stages.filter { $0.state.isPending }
    }

    public func stage(id: ReminderStage.ID) -> ReminderStage? {
        stages.first { $0.id == id }
    }

    /// The next reminder still expected to fire, earliest first.
    ///
    /// Stages without a concrete date sort last: a template stage that has not
    /// been resolved against an anchor has no claim to being "next".
    public var nextPendingStage: ReminderStage? {
        pendingStages
            .filter { $0.scheduledFor != nil }
            .min { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
    }

    /// Whether an equivalent follow-up is already waiting.
    ///
    /// The duplicate check, in one place. Two follow-ups of the same kind
    /// pending at the same moment are the same intervention, however many times
    /// the outcome that produced them was processed. The date comparison is
    /// deliberately coarse — to the minute — because a re-run a few hundred
    /// milliseconds later is the same plan, not a new one.
    public func hasPendingStage(kind: ReminderStageKind, at date: Date) -> Bool {
        pendingStages.contains { stage in
            guard stage.kind == kind, let scheduled = stage.scheduledFor else { return false }
            return abs(scheduled.timeIntervalSince(date)) < 60
        }
    }

    /// Applies an outcome to one stage, returning whether anything changed.
    ///
    /// Returns `false` when the stage is already resolved, which is what makes
    /// processing the same notification callback twice a no-op rather than a
    /// second follow-up.
    @discardableResult
    public mutating func recordOutcome(
        _ state: ReminderStageState,
        forStage id: ReminderStage.ID,
        at date: Date
    ) -> Bool {
        guard let index = stages.firstIndex(where: { $0.id == id }) else { return false }
        guard !stages[index].state.isResolved else { return false }
        stages[index].transition(to: state, at: date)
        return true
    }

    /// Calls off every reminder still waiting. Used when a task is resolved.
    ///
    /// Returns the stages that were actually cancelled, so the caller knows
    /// which platform requests to withdraw.
    @discardableResult
    public mutating func cancelPendingStages(at date: Date) -> [ReminderStage] {
        var cancelled: [ReminderStage] = []
        for index in stages.indices where !stages[index].state.isResolved {
            stages[index].transition(to: .cancelled, at: date)
            cancelled.append(stages[index])
        }
        return cancelled
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
    /// A reminder's moment passed with no response at all.
    ///
    /// Distinct from ``anchorPassed``: that one means the *task's* moment
    /// arrived unconfirmed, which is a worse fact. This one means an
    /// intervention went unanswered, which is a normal thing to happen several
    /// times before a deadline and should escalate rather than declare failure.
    case reminderMissed(at: Date)
    case snoozed(until: Date)
    case startedWorking(at: Date)
    case confirmedComplete(at: Date)
    case deferred(to: Date)
    case anchorPassed(at: Date)
    case cancelled(at: Date)
}
