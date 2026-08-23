import AssistantDomain
import ExecutiveSupport
import Foundation

/// The categories the app registers with iOS, and the buttons on them.
///
/// A notification with no category has one behaviour: you can swipe it away.
/// That single gesture is ambiguous — it means "I did it", "not now" and "stop
/// bothering me" — and the whole product rests on telling those apart. So every
/// reminder that wants an answer is delivered in a category that offers the
/// answers explicitly.
public enum AppleNotificationCategory: String, Hashable, Sendable, CaseIterable {
    /// Reminders that want a real answer: Done, Snooze, I'm on it.
    case confirmable = "assistant.category.confirmable"
    /// Reminders that are only telling you something. No buttons, and
    /// dismissing one resolves nothing, because there was nothing to resolve.
    case informational = "assistant.category.informational"

    /// Which category a request belongs in.
    ///
    /// Driven by the domain flag rather than by escalation level: how loud a
    /// reminder is and whether it needs an answer are separate questions, and
    /// a gentle nudge about something important still needs a Done button.
    public static func category(for request: NotificationRequest) -> AppleNotificationCategory {
        request.requiresCompletionConfirmation ? .confirmable : .informational
    }
}

/// The buttons, and the two responses iOS generates on its own.
public enum AppleNotificationAction: String, Hashable, Sendable, CaseIterable {
    case complete = "assistant.action.complete"
    case snooze = "assistant.action.snooze"
    /// "I'm on it." Engagement without a claim of completion — the state the
    /// task lifecycle calls `acknowledged`, and the honest answer for someone
    /// who has started but is not finished.
    case working = "assistant.action.working"

    /// The title shown on the button.
    ///
    /// Kept next to the identifier so a renamed button cannot drift away from
    /// the meaning the router assigns it.
    public var title: String {
        switch self {
        case .complete: return "Done"
        case .snooze: return "Later"
        case .working: return "I'm on it"
        }
    }

    /// True when tapping it should bring the app forward.
    ///
    /// All three are answerable from the lock screen without unlocking or
    /// launching anything, which is the point: an interruption that demands a
    /// full context switch to dismiss is the interruption people learn to
    /// ignore.
    public var opensApplication: Bool { false }

    /// True when the action destroys something. None of these do — "Done" ends
    /// a task's follow-up but that is recorded, reversible and expected.
    public var isDestructive: Bool { false }
}

/// The keys in a notification's `userInfo`.
///
/// `userInfo` is written to disk by the system, survives backups, and is
/// readable by anything that can read the notification. So it carries routing
/// metadata and nothing else — identifiers and one flag. No titles, no task
/// details, no memory context, no prompt text, no credentials. Everything the
/// app needs to show is loaded from the repositories once the routing has
/// found the right task.
public enum AppleNotificationPayloadKey {
    public static let schemaVersion = "assistant.v"
    public static let taskID = "assistant.task"
    public static let stageID = "assistant.stage"
    public static let requestID = "assistant.request"
    public static let requiresConfirmation = "assistant.confirm"
    /// The plan revision this notification was scheduled under.
    ///
    /// Section 54. It comes back with the user's answer and is compared against
    /// the plan as it stands then; a lower number means the reminder they are
    /// answering belonged to a schedule that has since been replaced.
    public static let planRevision = "assistant.rev"

    /// Bumped when the meaning of a key changes.
    ///
    /// Notifications outlive app versions: one scheduled a week ago is
    /// delivered by whatever build is installed when it fires. A payload from
    /// a version this build does not understand is ignored rather than
    /// guessed at.
    public static let currentSchemaVersion = "1"
}

/// The routing metadata carried by one notification.
public struct AppleNotificationPayload: Hashable, Sendable {
    public var requestID: NotificationRequest.ID
    public var taskID: TaskItem.ID?
    public var stageID: ReminderStage.ID?
    public var requiresConfirmation: Bool
    /// The plan revision at scheduling time. Nil for a notification scheduled
    /// by a build that predates revisions.
    public var planRevision: Int?

    public init(
        requestID: NotificationRequest.ID,
        taskID: TaskItem.ID? = nil,
        stageID: ReminderStage.ID? = nil,
        requiresConfirmation: Bool = true,
        planRevision: Int? = nil
    ) {
        self.requestID = requestID
        self.taskID = taskID
        self.stageID = stageID
        self.requiresConfirmation = requiresConfirmation
        self.planRevision = planRevision
    }

    public init(request: NotificationRequest) {
        self.init(
            requestID: request.id,
            taskID: request.relatedTaskID,
            stageID: request.stageID,
            requiresConfirmation: request.requiresCompletionConfirmation,
            planRevision: request.planRevision
        )
    }

    /// Flattened to strings, which is what the system stores well.
    ///
    /// `userInfo` accepts `Any` and silently tolerates values that do not
    /// survive its property-list encoding. Strings always do, so nothing is
    /// lost between scheduling a reminder and answering it.
    public var userInfo: [String: String] {
        var values = [
            AppleNotificationPayloadKey.schemaVersion:
                AppleNotificationPayloadKey.currentSchemaVersion,
            AppleNotificationPayloadKey.requestID: requestID.rawValue.uuidString,
            AppleNotificationPayloadKey.requiresConfirmation: requiresConfirmation ? "1" : "0",
        ]
        if let taskID {
            values[AppleNotificationPayloadKey.taskID] = taskID.rawValue.uuidString
        }
        if let stageID {
            values[AppleNotificationPayloadKey.stageID] = stageID.rawValue.uuidString
        }
        if let planRevision {
            values[AppleNotificationPayloadKey.planRevision] = String(planRevision)
        }
        return values
    }

    /// Reads a payload back, or nil if this notification is not one of ours.
    public static func decode(_ userInfo: [String: String]) -> AppleNotificationPayload? {
        guard userInfo[AppleNotificationPayloadKey.schemaVersion]
            == AppleNotificationPayloadKey.currentSchemaVersion
        else { return nil }
        guard let rawRequest = userInfo[AppleNotificationPayloadKey.requestID],
              let requestID = NotificationRequest.ID(uuidString: rawRequest)
        else { return nil }

        return AppleNotificationPayload(
            requestID: requestID,
            taskID: userInfo[AppleNotificationPayloadKey.taskID]
                .flatMap { TaskItem.ID(uuidString: $0) },
            stageID: userInfo[AppleNotificationPayloadKey.stageID]
                .flatMap { ReminderStage.ID(uuidString: $0) },
            // Absent means "assume an answer is wanted". The failure modes are
            // not symmetric: treating a confirmable reminder as informational
            // silently ends support for that task, while the reverse merely
            // asks a question that did not need asking.
            requiresConfirmation: userInfo[AppleNotificationPayloadKey.requiresConfirmation] != "0",
            // Absent means "this notification predates revisions", which the
            // follow-up service reads as "cannot prove it is stale, so trust
            // it". Refusing every in-flight reminder across an app update would
            // be the worse failure by a distance.
            planRevision: userInfo[AppleNotificationPayloadKey.planRevision].flatMap(Int.init)
        )
    }
}

/// What the user did, in terms this module can reason about without importing
/// UserNotifications.
public struct AppleNotificationResponse: Hashable, Sendable {
    /// The system identifier of the notification, e.g. `assistant.reminder.…`.
    public var systemIdentifier: String
    /// Either one of our action identifiers or one of Apple's two built-ins.
    public var actionIdentifier: String
    public var userInfo: [String: String]

    /// Apple's identifier for "the user tapped the notification itself".
    ///
    /// Hard-coded rather than referenced from the framework so this file, and
    /// the tests that exercise it, need no import. The constant is part of
    /// Apple's public API and the delegate asserts it matches at the boundary.
    public static let defaultActionIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"
    /// Apple's identifier for "the user swiped it away".
    public static let dismissActionIdentifier = "com.apple.UNNotificationDismissActionIdentifier"

    public init(
        systemIdentifier: String,
        actionIdentifier: String,
        userInfo: [String: String]
    ) {
        self.systemIdentifier = systemIdentifier
        self.actionIdentifier = actionIdentifier
        self.userInfo = userInfo
    }
}

/// Where a notification response should be delivered.
public enum AppleNotificationRoute: Hashable, Sendable {
    /// Report this outcome through `FollowUpService`.
    ///
    /// `revision` travels with it so the service can decline an answer to a
    /// reminder that has since been superseded (section 18). This layer does
    /// not make that judgement itself: it has no repositories and cannot see
    /// the plan, which is the point — the router parses, the service decides.
    case outcome(
        ReminderOutcome,
        task: TaskItem.ID,
        stage: ReminderStage.ID?,
        revision: Int?
    )
    /// The user tapped the notification. Show them the task; change nothing.
    case open(task: TaskItem.ID, stage: ReminderStage.ID?)
    /// Not ours, or not understood. The reason is a fixed string written here,
    /// never anything taken from the payload.
    case ignored(reason: String)
}

/// Turns a notification response into a routing decision.
///
/// This is the whole of the delegate's thinking, extracted so it can be tested
/// without a notification centre, an app bundle or a device. The delegate that
/// remains is a type conversion and a call.
///
/// It reads nothing and writes nothing. Given a response it returns a decision;
/// the caller performs it. That is what keeps a notification callback — which
/// arrives on the main thread, at an arbitrary moment, possibly during launch —
/// from being a place where business rules or database writes live.
public enum AppleNotificationRouter {
    /// The rule the product is built on, as one function.
    ///
    /// Read the `.dismiss` case next to the `.complete` case. They are adjacent
    /// gestures on the same notification and they mean opposite things, and
    /// every version of this feature that has ever shipped anywhere gets this
    /// wrong by treating "the notification went away" as "the task got done".
    public static func route(_ response: AppleNotificationResponse) -> AppleNotificationRoute {
        guard AppleNotificationIdentity.isOurs(response.systemIdentifier) else {
            return .ignored(reason: "Not an assistant reminder")
        }
        guard let payload = AppleNotificationPayload.decode(response.userInfo) else {
            return .ignored(reason: "Unrecognised reminder payload")
        }
        guard let taskID = payload.taskID else {
            // A notification with no task behind it — `scheduleNotification`
            // can produce one. There is no lifecycle to advance, so there is
            // nothing to route.
            return .ignored(reason: "Reminder is not attached to a task")
        }

        if let action = AppleNotificationAction(rawValue: response.actionIdentifier) {
            switch action {
            case .complete:
                return .outcome(
                    .completed,
                    task: taskID,
                    stage: payload.stageID,
                    revision: payload.planRevision
                )
            case .snooze:
                // `until: nil` on purpose. The button says "Later", not a
                // duration, and the plan's own snooze policy — which knows how
                // many times this task has already been put off and how close
                // its deadline is — decides when later means. Hard-coding nine
                // minutes here would quietly override that.
                return .outcome(
                    .snoozed(until: nil),
                    task: taskID,
                    stage: payload.stageID,
                    revision: payload.planRevision
                )
            case .working:
                return .outcome(
                    .acknowledged,
                    task: taskID,
                    stage: payload.stageID,
                    revision: payload.planRevision
                )
            }
        }

        switch response.actionIdentifier {
        case AppleNotificationResponse.dismissActionIdentifier:
            // Swiped away. **Not** completion, and this is the line that says
            // so. The task stays open, the follow-up ladder escalates, and the
            // user hears about it again — which is the entire reason this app
            // exists rather than a calendar alert.
            return .outcome(
                .dismissed,
                task: taskID,
                stage: payload.stageID,
                revision: payload.planRevision
            )

        case AppleNotificationResponse.defaultActionIdentifier:
            // Tapped it open. That is engagement, but it is not a claim about
            // the task, so no outcome is recorded — the app just shows the
            // task and lets the user say what is true.
            return .open(task: taskID, stage: payload.stageID)

        default:
            return .ignored(reason: "Unrecognised notification action")
        }
    }
}
