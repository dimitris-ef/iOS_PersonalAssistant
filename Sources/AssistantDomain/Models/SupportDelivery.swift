import Foundation

/// Whether the operating system has actually been asked to deliver a stage.
///
/// ## Why this is separate from `ReminderStageState`
///
/// Section 12, and it is the distinction the whole milestone turns on:
/// **scheduled ≠ delivered ≠ completed.** `ReminderStageState` answers *what
/// became of the reminder as far as the user is concerned* — delivered,
/// dismissed, snoozed, missed. This answers a different question that nobody
/// outside the platform layer should care about: *does iOS currently hold a
/// request for this?*
///
/// Folding them into one enum would mean a stage that failed to schedule
/// because notifications are switched off had to pick between lying (`pending`)
/// and destroying its own lifecycle (`missed`). Kept apart, the stage is
/// `pending` and undelivered, which is exactly the truth, and the Settings
/// screen can say so.
public enum StageDeliveryState: String, Hashable, Codable, Sendable, CaseIterable {
    /// Decided, not yet handed to the OS. Also what a stage becomes when a
    /// newer plan revision supersedes it, until reconciliation catches up.
    case planned
    /// Handed to `UNUserNotificationCenter` or AlarmKit, and accepted.
    case scheduled
    /// The OS refused, for a reason that may not recur — a transient error, a
    /// full queue. Reconciliation retries it, bounded.
    case failed
    /// The OS refused for a reason that will not change by retrying:
    /// notification permission is denied, or the device has no AlarmKit.
    /// Section 62 — retrying this every launch is how an app burns battery
    /// pretending a decision the user made is temporary.
    case unavailable

    /// Whether reconciliation should try again.
    public var isRetryable: Bool { self == .planned || self == .failed }

    /// Whether iOS is believed to be holding a request for this stage.
    public var isLive: Bool { self == .scheduled }
}

/// What has happened when the app tried to hand one stage to the OS.
///
/// Small on purpose (section 16): a state, a count, a timestamp and — only when
/// something went wrong — a short reason. Not a serialized `UNNotificationRequest`
/// (section 55): the request is rebuilt from domain data every time, so storing
/// one would be storing a stale copy of something derivable.
public struct StageDelivery: Hashable, Codable, Sendable {
    public var state: StageDeliveryState
    /// When the app last asked the OS. Nil before the first attempt.
    public var lastAttemptAt: Date?
    /// How many times scheduling has been attempted. Bounds the retry loop.
    public var attempts: Int
    /// Why the last attempt failed. Short, and never the task's own text.
    public var failureReason: String?
    /// The plan revision this stage was scheduled under.
    ///
    /// Section 17. When the plan is recalculated the revision moves, and a
    /// stage still carrying the old one is a stage whose OS request describes a
    /// time that is no longer true.
    public var scheduledRevision: Int?

    public init(
        state: StageDeliveryState = .planned,
        lastAttemptAt: Date? = nil,
        attempts: Int = 0,
        failureReason: String? = nil,
        scheduledRevision: Int? = nil
    ) {
        self.state = state
        self.lastAttemptAt = lastAttemptAt
        self.attempts = attempts
        self.failureReason = failureReason
        self.scheduledRevision = scheduledRevision
    }

    public static let planned = StageDelivery()

    /// Records a successful hand-off.
    public mutating func succeeded(at date: Date, revision: Int) {
        state = .scheduled
        lastAttemptAt = date
        attempts += 1
        failureReason = nil
        scheduledRevision = revision
    }

    /// Records a refusal.
    ///
    /// `isPermanent` is the caller's judgement about the *kind* of failure, not
    /// about how many times it has happened: permission denied is permanent on
    /// the first try, and a transient error stays retryable however often it
    /// recurs — the attempt count is what stops that looping.
    public mutating func failed(at date: Date, reason: String, isPermanent: Bool) {
        state = isPermanent ? .unavailable : .failed
        lastAttemptAt = date
        attempts += 1
        // Truncated, and deliberately: this string reaches logs and diagnostics,
        // and an underlying error can carry more detail than belongs there.
        failureReason = String(reason.prefix(120))
    }

    /// Marks the stage as no longer represented in the OS.
    public mutating func withdrawn() {
        state = .planned
        scheduledRevision = nil
    }
}

/// One support action that has already been applied.
///
/// ## Why this is not the tool execution ledger
///
/// Section 53 asks for the Part 7 ledger to be reused if it covers this
/// cleanly, and it does not — for one structural reason. `ToolExecutionLedger`
/// is scoped to a single assistant turn and lives in memory: its whole job is
/// to stop one agent loop executing the same call twice, and it is discarded
/// when the turn ends. A notification callback arrives when there is no turn,
/// often in a process that has just launched to handle it, and the duplicate it
/// has to defend against may arrive minutes later or after a relaunch. Nothing
/// in-memory can see that.
///
/// So this is a small persisted table with one job, rather than a
/// generalisation of the other one into something that serves neither well.
///
/// ## Identity
///
/// Derived, never allocated (section 49): the same stage, the same action and
/// the same plan revision produce the same identifier on any device at any
/// time, which is what makes "have I already done this?" answerable without
/// coordination.
public struct HandledSupportAction: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<HandledSupportAction>

    public var id: ID
    public var stageID: ReminderStage.ID
    public var taskID: TaskItem.ID
    /// The outcome's raw value. A string rather than the enum so a payload from
    /// an older build does not fail to decode.
    public var action: String
    /// The plan revision the action was applied under.
    public var revision: Int
    public var handledAt: Date

    public init(
        stageID: ReminderStage.ID,
        taskID: TaskItem.ID,
        action: String,
        revision: Int,
        handledAt: Date
    ) {
        self.id = Self.identity(stage: stageID, action: action, revision: revision)
        self.stageID = stageID
        self.taskID = taskID
        self.action = action
        self.revision = revision
        self.handledAt = handledAt
    }

    /// The identifier for one (stage, action, revision) triple.
    ///
    /// Revision is part of the identity on purpose. A snooze at revision 3 and
    /// a snooze at revision 4 are genuinely two different actions — the plan
    /// changed in between — and collapsing them would mean the second one
    /// silently did nothing.
    public static func identity(
        stage: ReminderStage.ID,
        action: String,
        revision: Int
    ) -> ID {
        ID.deterministic(
            namespace: "support-action",
            name: "\(stage.rawValue.uuidString)/\(action)/\(revision)"
        )
    }
}
