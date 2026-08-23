import Foundation

/// Where an active support session has got to.
///
/// The vocabulary a Live Activity presents. It mirrors what Part 8 already
/// decided about preparation, leaving and doing — it does not add a second
/// lifecycle, and nothing here is ever the reason a task changes state.
public enum SupportActivityPhase: String, Codable, Sendable, CaseIterable {
    /// Getting ready. Steps remain.
    case preparing
    /// Ready, and the leave time is approaching.
    case leaving
    /// Under way.
    case inProgress
    /// Waiting for the moment itself — the appointment, the meeting.
    case waiting
    /// Finished. The last state a Live Activity shows before it ends.
    case finished

    /// Two words at most, for a compact presentation.
    public var shortLabel: String {
        switch self {
        case .preparing: return "Getting ready"
        case .leaving: return "Leave soon"
        case .inProgress: return "In progress"
        case .waiting: return "Up next"
        case .finished: return "Done"
        }
    }
}

/// Why this activity exists at all.
public enum SupportActivityKind: String, Codable, Sendable, CaseIterable {
    /// Preparing for something with a fixed time — the classic case.
    case appointmentPreparation
    /// A "Help me start" session the user asked for.
    case startSession
    /// A high-importance task with a deadline close enough to matter.
    case deadline
    /// One occurrence of a routine, inside its window.
    case routineWindow
}

/// Everything a Live Activity draws, and nothing else.
///
/// Section 50, and the reason this is a separate type from the domain's own:
/// ActivityKit content state is serialized by the system, is size-limited, and
/// is visible on a locked screen. A `TaskItem` carries notes and a
/// `ReminderPlan` carries a stage history; neither belongs in either place.
///
/// Deliberately free of `ActivityKit`. Section 49 asks that ActivityKit types
/// stay out of the core — this is how: the domain produces *this*, and one thin
/// adapter in the iOS layer copies it into an `ActivityAttributes.ContentState`.
/// That adapter is the only file in the project that has to import ActivityKit,
/// and this value is what all the tests can therefore assert on.
public struct SupportActivityContent: Codable, Sendable, Hashable {
    /// What is happening. Already privacy-filtered by the builder.
    public var title: String
    public var phase: SupportActivityPhase
    /// The moment this is counting towards: the leave time while preparing,
    /// the start time while waiting.
    ///
    /// Handed to the system as a date so the countdown ticks without this app
    /// running (section 60). Nothing here formats a duration.
    public var targetDate: Date?
    /// One short instruction — "Pack documents". Nil when there isn't one.
    public var nextStep: String?
    /// How many preparation steps are done, out of how many. Nil when the
    /// activity is not a step-by-step one.
    public var completedSteps: Int?
    public var totalSteps: Int?

    public init(
        title: String,
        phase: SupportActivityPhase,
        targetDate: Date? = nil,
        nextStep: String? = nil,
        completedSteps: Int? = nil,
        totalSteps: Int? = nil
    ) {
        self.title = title
        self.phase = phase
        self.targetDate = targetDate
        self.nextStep = nextStep
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
    }

    /// A one-line summary for the minimal Dynamic Island presentation and for
    /// accessibility, where there is room for a sentence but not a layout.
    public var accessibilitySummary: String {
        var parts = [title, phase.shortLabel]
        if let nextStep { parts.append("Next: \(nextStep)") }
        return parts.joined(separator: ". ")
    }
}

/// The mapping between one domain task and one system-presented activity.
///
/// Persisted in the shared container so that after a relaunch the app can find
/// out which activities it started, without asking ActivityKit to be the
/// source of truth (section 54).
public struct LiveActivityDescriptor: Codable, Sendable, Equatable, Identifiable {
    /// The task the activity is about. Also the identity: one task, at most one
    /// activity, which is what stops a relaunch starting a second one.
    public var id: UUID
    public var kind: SupportActivityKind
    public var content: SupportActivityContent
    /// The system's own identifier for the running activity, once it has one.
    /// Nil before the request succeeds, and on a device where Live Activities
    /// are switched off.
    public var systemActivityID: String?
    public var startedAt: Date
    /// When this activity stops being worth showing whatever else happens —
    /// handed to ActivityKit as a dismissal date so a forgotten activity does
    /// not sit on the Lock Screen forever.
    public var staleAt: Date?

    public init(
        id: UUID,
        kind: SupportActivityKind,
        content: SupportActivityContent,
        systemActivityID: String? = nil,
        startedAt: Date,
        staleAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.systemActivityID = systemActivityID
        self.startedAt = startedAt
        self.staleAt = staleAt
    }
}

/// Which activities the app believes are running.
///
/// Written by the app, read by the app after a relaunch. The widget extension
/// does not read it: ActivityKit hands the extension its content state
/// directly, and giving the extension a second opinion about what is running is
/// exactly the duplication section 54 warns about.
public struct LiveActivityRegistry: SystemSurfaceSnapshot {
    public static let storageKey = "live-activities"

    public var snapshotVersion: Int
    public var generatedAt: Date
    public var validUntil: Date?
    public var activities: [LiveActivityDescriptor]

    public init(
        snapshotVersion: Int = LiveActivityRegistry.currentVersion,
        generatedAt: Date,
        validUntil: Date? = nil,
        activities: [LiveActivityDescriptor] = []
    ) {
        self.snapshotVersion = snapshotVersion
        self.generatedAt = generatedAt
        self.validUntil = validUntil
        self.activities = activities
    }

    public func descriptor(for taskID: UUID) -> LiveActivityDescriptor? {
        activities.first { $0.id == taskID }
    }
}
