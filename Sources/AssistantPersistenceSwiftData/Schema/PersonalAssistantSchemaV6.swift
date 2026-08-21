#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 6: recurring responsibilities, dependencies and preparation.
//
// Three things arrive together because they are three halves of the same
// feature — helping someone prepare for, sequence and recover from the things
// they have to do:
//
//  1. `SDRoutine`, a new entity. The *definition* of a recurring
//     responsibility. Its occurrences are ordinary `SDTask` rows carrying
//     `routineID` and `occurrenceDate`, which is what lets recurrence reuse the
//     whole existing lifecycle rather than growing a second one.
//
//  2. `SDTask` gains dependency and preparation columns, plus the two counters
//     adaptive escalation reads.
//
//  3. Nothing is removed and nothing is retyped.
//
// ## Why preparation steps are JSON and dependencies are a column
//
// `dependsOn` is `[UUID]?` — an array of primitives, exactly like
// `recurrenceWeekdays` already is, and something a future migration might
// genuinely want to query.
//
// Preparation steps are stored as JSON, following the precedent `SDAction`
// already set: a value that is always read back whole with its parent and never
// queried by field earns a blob rather than a table. Modelling four fields and
// an ordering as a related entity would add a migration step, an inverse
// relationship and a delete rule to no benefit the app can name.
//
// ## Why this stays inferrable
//
// Every added property on an existing model is either optional or carries a
// declared default, and the one new model is a new entity. That is the case
// SwiftData infers from the store's own metadata — the same reasoning set out
// in `PersonalAssistantSchemaV2`, which also explains the debt these versions
// are carrying by sharing model classes and when it must be paid off.
//
// ## The dormant columns
//
// `SDTask.recurrenceKind` and friends are still here and are no longer written.
// Recurrence became a property of a routine, not of a task, and a task-level
// recurrence would be a second place to define the same thing. The columns stay
// because a schema never deletes data; nothing ever wrote to them, so there is
// none to lose either way.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV6: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            SDConversation.self,
            SDMessage.self,
            SDActionPlan.self,
            SDAction.self,
            SDToolResult.self,
            SDMemory.self,
            SDTask.self,
            SDRoutine.self,
            SDReminderPlan.self,
            SDReminderStage.self,
            SDAssistantSettings.self,
            SDUserProfile.self,
        ]
    }
}

/// A recurring responsibility.
///
/// Never completed, never missed, never in progress: those things happen to a
/// particular Thursday, and a particular Thursday is a task. What lives here is
/// the rule, the policy for a late occurrence, and the two dates that say how
/// it has been going.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDRoutine {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var details: String?
    public var importanceRaw: String
    /// False when paused. Existing occurrences keep their own lifecycle.
    public var isActive: Bool

    /// `RecurrenceRule`, decomposed so a future query can ask "which routines
    /// fall on a Thursday" without decoding every row.
    public var frequencyRaw: String
    public var interval: Int
    public var weekdays: [Int]
    public var dayOfMonth: Int?
    /// Minutes from midnight. One integer rather than two columns, because a
    /// time of day is one value and splitting it invites half of it being nil.
    public var minuteOfDay: Int
    public var recurrenceStart: Date
    public var recurrenceEnd: Date?

    /// `RoutineRecoveryPolicy`.
    public var recoveryEnabled: Bool
    public var recoveryWindow: Double
    public var recoveryAllowsNextDay: Bool

    public var preparationDuration: Double?
    public var travelDuration: Double?
    /// `[PreparationStep]` as JSON. See the note at the top of this file.
    public var preparationStepsJSON: Data?

    public var lastCompletedAt: Date?
    public var lastMissedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        title: String,
        details: String?,
        importanceRaw: String,
        isActive: Bool,
        frequencyRaw: String,
        interval: Int,
        weekdays: [Int],
        dayOfMonth: Int?,
        minuteOfDay: Int,
        recurrenceStart: Date,
        recurrenceEnd: Date?,
        recoveryEnabled: Bool,
        recoveryWindow: Double,
        recoveryAllowsNextDay: Bool,
        preparationDuration: Double?,
        travelDuration: Double?,
        preparationStepsJSON: Data?,
        lastCompletedAt: Date?,
        lastMissedAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.importanceRaw = importanceRaw
        self.isActive = isActive
        self.frequencyRaw = frequencyRaw
        self.interval = interval
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
        self.minuteOfDay = minuteOfDay
        self.recurrenceStart = recurrenceStart
        self.recurrenceEnd = recurrenceEnd
        self.recoveryEnabled = recoveryEnabled
        self.recoveryWindow = recoveryWindow
        self.recoveryAllowsNextDay = recoveryAllowsNextDay
        self.preparationDuration = preparationDuration
        self.travelDuration = travelDuration
        self.preparationStepsJSON = preparationStepsJSON
        self.lastCompletedAt = lastCompletedAt
        self.lastMissedAt = lastMissedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

#endif
