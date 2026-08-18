#if canImport(SwiftData)

import Foundation
import SwiftData

// The initial persistent schema.
//
// Everything in this file is *storage*. None of it appears above the repository
// layer: the assistant, the view models and the tool system deal only in the
// domain types from `AssistantDomain`, which know nothing about SwiftData.
//
// Two rules shaped these models:
//
// 1. **The domain's identifier is the key.** Every entity stores the domain
//    `UUID` and is looked up by it. SwiftData's own object identity is an
//    implementation detail we never depend on, so a value loaded, edited and
//    saved again updates the same row instead of inserting a second one.
//
// 2. **Enums with associated values are decomposed, not encoded.** A
//    `TimingPreference` becomes a discriminator string plus the dates it
//    carries. That is more columns than a blob, but it is inspectable, it can
//    be queried later, and — the reason that matters most — a future schema
//    version can migrate a column. It cannot migrate the inside of an opaque
//    payload.
//
// The one deliberate exception is `SDAction.requestJSON`; see the note there.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            SDConversation.self,
            SDMessage.self,
            SDActionPlan.self,
            SDAction.self,
            SDToolResult.self,
            SDMemory.self,
            SDTask.self,
            SDReminderPlan.self,
            SDReminderStage.self,
            SDAssistantSettings.self,
            SDUserProfile.self,
        ]
    }
}

// MARK: - Conversations

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDConversation {
    /// The domain `Conversation.ID`. Unique so a re-save updates in place.
    @Attribute(.unique) public var id: UUID
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// Cascade: deleting a conversation must not leave its messages behind.
    /// This is declared here rather than handled by the caller so no future
    /// screen can forget to clean up.
    @Relationship(deleteRule: .cascade, inverse: \SDMessage.conversation)
    public var messages: [SDMessage]

    @Relationship(deleteRule: .cascade, inverse: \SDActionPlan.conversation)
    public var actionPlans: [SDActionPlan]

    public init(id: UUID, title: String?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = []
        self.actionPlans = []
    }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDMessage {
    @Attribute(.unique) public var id: UUID
    public var roleRaw: String
    public var text: String
    public var createdAt: Date
    /// Links a reply to the actions it produced. Stored as the raw identifier
    /// rather than a relationship because the domain models it that way.
    public var actionPlanID: UUID?
    /// Position within the conversation.
    ///
    /// Ordering is by `createdAt`, but seeded and rapidly-appended messages can
    /// share a timestamp, and a fetch must never depend on the order a database
    /// happens to return rows in. This is the tiebreak.
    public var sequence: Int

    public var conversation: SDConversation?

    public init(
        id: UUID,
        roleRaw: String,
        text: String,
        createdAt: Date,
        actionPlanID: UUID?,
        sequence: Int
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.text = text
        self.createdAt = createdAt
        self.actionPlanID = actionPlanID
        self.sequence = sequence
    }
}

// MARK: - Assistant actions

/// The structured content shown beneath an assistant reply.
///
/// Persisted so the action cards — "haircut added, and here is how I'll get you
/// there" — are still there after a relaunch, rather than the transcript
/// silently degrading to plain text.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDActionPlan {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date

    public var conversation: SDConversation?

    @Relationship(deleteRule: .cascade, inverse: \SDAction.plan)
    public var actions: [SDAction]

    @Relationship(deleteRule: .cascade, inverse: \SDToolResult.plan)
    public var results: [SDToolResult]

    public init(id: UUID, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.actions = []
        self.results = []
    }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDAction {
    @Attribute(.unique) public var id: UUID
    /// Denormalised from the request so the kind is queryable and readable in a
    /// database browser without decoding anything.
    public var toolKindRaw: String
    public var originRaw: String
    public var authorizationRaw: String
    public var rationale: String?
    public var sourceCallID: UUID?
    public var sequence: Int

    /// The typed tool input, encoded as JSON.
    ///
    /// This is the one payload in the schema that is not decomposed into
    /// columns, and the choice is deliberate. `ToolRequest` is a closed union of
    /// fifteen input types; modelling it relationally means fifteen tables that
    /// exist only to reconstruct a value nothing ever queries by field — the
    /// transcript reads it back whole, or not at all.
    ///
    /// It is also not an invented format: this is the same `name` + JSON
    /// arguments shape the tool pipeline already speaks, so a stored action is
    /// exactly a recorded tool call. `toolKindRaw` above keeps the
    /// discriminator queryable, which is what a migration would need.
    public var requestJSON: Data

    public var plan: SDActionPlan?

    public init(
        id: UUID,
        toolKindRaw: String,
        originRaw: String,
        authorizationRaw: String,
        rationale: String?,
        sourceCallID: UUID?,
        sequence: Int,
        requestJSON: Data
    ) {
        self.id = id
        self.toolKindRaw = toolKindRaw
        self.originRaw = originRaw
        self.authorizationRaw = authorizationRaw
        self.rationale = rationale
        self.sourceCallID = sourceCallID
        self.sequence = sequence
        self.requestJSON = requestJSON
    }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDToolResult {
    @Attribute(.unique) public var id: UUID
    public var actionID: UUID
    public var kindRaw: String
    /// `ToolOutcome` split into its discriminator and the one string some of
    /// its cases carry — the platform name for `.simulated`, the reason for the
    /// rest. Keeping the discriminator a column is what lets the UI honestly
    /// badge a restored card as simulated.
    public var outcomeKindRaw: String
    public var outcomeDetail: String?
    public var message: String
    public var producedAt: Date
    public var sequence: Int

    public var plan: SDActionPlan?

    public init(
        id: UUID,
        actionID: UUID,
        kindRaw: String,
        outcomeKindRaw: String,
        outcomeDetail: String?,
        message: String,
        producedAt: Date,
        sequence: Int
    ) {
        self.id = id
        self.actionID = actionID
        self.kindRaw = kindRaw
        self.outcomeKindRaw = outcomeKindRaw
        self.outcomeDetail = outcomeDetail
        self.message = message
        self.producedAt = producedAt
        self.sequence = sequence
    }
}

// MARK: - Memory

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDMemory {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var content: String
    public var salience: Double
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var sourceRaw: String

    // MARK: Schema V3 — trust
    //
    // Optional so the V2 → V3 migration is inferrable. A row written before
    // this feature has no recorded confidence; the mapper derives one from the
    // source it *did* record, which is better evidence than a blanket default.

    /// How sure the application is that this memory is true. Nil on rows
    /// predating schema V3.
    public var confidenceValue: Double?

    public init(
        id: UUID,
        kindRaw: String,
        content: String,
        salience: Double,
        tags: [String],
        createdAt: Date,
        updatedAt: Date,
        lastUsedAt: Date?,
        sourceRaw: String,
        confidenceValue: Double? = nil
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.content = content
        self.salience = salience
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.sourceRaw = sourceRaw
        self.confidenceValue = confidenceValue
    }
}

// MARK: - Tasks

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDTask {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var details: String?
    /// The ADHD status machine's state, including the distinction the whole
    /// product rests on: `reminded` is not `completed`.
    public var statusRaw: String
    public var importanceRaw: String

    /// `TimingPreference`, decomposed. `timingKind` is the case; the rest is
    /// whatever that case carries.
    public var timingKind: String
    public var timingDate: Date?
    public var timingWindowStart: Date?
    public var timingWindowEnd: Date?

    public var deadline: Date?
    public var preparationDuration: Double?
    public var travelDuration: Double?

    /// `RecurrenceRule`, decomposed. Nil `recurrenceKind` means no recurrence.
    public var recurrenceKind: String?
    public var recurrenceInterval: Int?
    public var recurrenceWeekdays: [Int]?
    public var recurrenceDay: Int?

    public var linkedCalendarItemID: UUID?
    public var reminderPlanID: UUID?
    public var followUpCount: Int
    public var snoozeCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID,
        title: String,
        details: String?,
        statusRaw: String,
        importanceRaw: String,
        timingKind: String,
        timingDate: Date?,
        timingWindowStart: Date?,
        timingWindowEnd: Date?,
        deadline: Date?,
        preparationDuration: Double?,
        travelDuration: Double?,
        recurrenceKind: String?,
        recurrenceInterval: Int?,
        recurrenceWeekdays: [Int]?,
        recurrenceDay: Int?,
        linkedCalendarItemID: UUID?,
        reminderPlanID: UUID?,
        followUpCount: Int,
        snoozeCount: Int,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.statusRaw = statusRaw
        self.importanceRaw = importanceRaw
        self.timingKind = timingKind
        self.timingDate = timingDate
        self.timingWindowStart = timingWindowStart
        self.timingWindowEnd = timingWindowEnd
        self.deadline = deadline
        self.preparationDuration = preparationDuration
        self.travelDuration = travelDuration
        self.recurrenceKind = recurrenceKind
        self.recurrenceInterval = recurrenceInterval
        self.recurrenceWeekdays = recurrenceWeekdays
        self.recurrenceDay = recurrenceDay
        self.linkedCalendarItemID = linkedCalendarItemID
        self.reminderPlanID = reminderPlanID
        self.followUpCount = followUpCount
        self.snoozeCount = snoozeCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

// MARK: - Reminder plans

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDReminderPlan {
    @Attribute(.unique) public var id: UUID

    /// `ReminderSubject.Reference`, decomposed. Exactly one of the three id
    /// columns is populated, selected by `subjectReferenceKind`.
    public var subjectReferenceKind: String
    public var subjectTaskID: UUID?
    public var subjectCalendarItemID: UUID?
    public var subjectFreeform: String?

    public var subjectTitle: String
    public var subjectImportanceRaw: String
    public var subjectIsTimeFixed: Bool
    public var subjectPreparationDuration: Double?
    public var subjectTravelDuration: Double?

    /// `ReminderAnchor`, decomposed.
    public var anchorKind: String
    public var anchorDate: Date?
    public var anchorWindowStart: Date?
    public var anchorWindowEnd: Date?

    public var followUpIsEnabled: Bool
    public var followUpMaximum: Int
    public var followUpInterval: Double
    public var followUpEscalatesEachTime: Bool

    public var snoozeIsAllowed: Bool
    public var snoozeDefaultDuration: Double
    public var snoozeMaximum: Int
    public var snoozeEscalateAfter: Int

    public var completionRequiresExplicitConfirmation: Bool
    public var completionMarkMissedAfter: Double?

    public var createdAt: Date
    public var generatedBy: String

    /// Stages are their own entity rather than an encoded array: they are the
    /// part of a plan most likely to be queried and updated one at a time
    /// ("which stage fires next", "mark this stage acknowledged"), and the part
    /// most likely to grow new fields.
    @Relationship(deleteRule: .cascade, inverse: \SDReminderStage.plan)
    public var stages: [SDReminderStage]

    public init(
        id: UUID,
        subjectReferenceKind: String,
        subjectTaskID: UUID?,
        subjectCalendarItemID: UUID?,
        subjectFreeform: String?,
        subjectTitle: String,
        subjectImportanceRaw: String,
        subjectIsTimeFixed: Bool,
        subjectPreparationDuration: Double?,
        subjectTravelDuration: Double?,
        anchorKind: String,
        anchorDate: Date?,
        anchorWindowStart: Date?,
        anchorWindowEnd: Date?,
        followUpIsEnabled: Bool,
        followUpMaximum: Int,
        followUpInterval: Double,
        followUpEscalatesEachTime: Bool,
        snoozeIsAllowed: Bool,
        snoozeDefaultDuration: Double,
        snoozeMaximum: Int,
        snoozeEscalateAfter: Int,
        completionRequiresExplicitConfirmation: Bool,
        completionMarkMissedAfter: Double?,
        createdAt: Date,
        generatedBy: String
    ) {
        self.id = id
        self.subjectReferenceKind = subjectReferenceKind
        self.subjectTaskID = subjectTaskID
        self.subjectCalendarItemID = subjectCalendarItemID
        self.subjectFreeform = subjectFreeform
        self.subjectTitle = subjectTitle
        self.subjectImportanceRaw = subjectImportanceRaw
        self.subjectIsTimeFixed = subjectIsTimeFixed
        self.subjectPreparationDuration = subjectPreparationDuration
        self.subjectTravelDuration = subjectTravelDuration
        self.anchorKind = anchorKind
        self.anchorDate = anchorDate
        self.anchorWindowStart = anchorWindowStart
        self.anchorWindowEnd = anchorWindowEnd
        self.followUpIsEnabled = followUpIsEnabled
        self.followUpMaximum = followUpMaximum
        self.followUpInterval = followUpInterval
        self.followUpEscalatesEachTime = followUpEscalatesEachTime
        self.snoozeIsAllowed = snoozeIsAllowed
        self.snoozeDefaultDuration = snoozeDefaultDuration
        self.snoozeMaximum = snoozeMaximum
        self.snoozeEscalateAfter = snoozeEscalateAfter
        self.completionRequiresExplicitConfirmation = completionRequiresExplicitConfirmation
        self.completionMarkMissedAfter = completionMarkMissedAfter
        self.createdAt = createdAt
        self.generatedBy = generatedBy
        self.stages = []
    }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDReminderStage {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var channelRaw: String
    public var escalationRaw: String
    public var message: String
    /// The ADHD rule at stage level: dismissing is not confirming.
    public var requiresConfirmation: Bool
    public var sequence: Int

    /// `ReminderOffset`, decomposed.
    public var offsetKind: String
    public var offsetInterval: Double?
    public var offsetDays: Int?
    public var offsetHour: Int?
    public var offsetMinute: Int?
    public var offsetDate: Date?

    // MARK: Schema V2 — lifecycle
    //
    // All three are optional so the V1 → V2 migration is inferrable. A row
    // written before this feature reads back with `stateRaw == nil`, which the
    // mapper resolves to `.pending`: an old reminder is one still waiting, never
    // one already dealt with.

    /// `ReminderStageState`. Nil on rows predating schema V2.
    public var stateRaw: String?
    public var stateChangedAt: Date?
    /// The concrete moment this stage is due, for follow-ups and for
    /// reconciliation. Nil on template stages that resolve against the plan's
    /// anchor, and on rows predating schema V2.
    public var scheduledFor: Date?

    public var plan: SDReminderPlan?

    public init(
        id: UUID,
        kindRaw: String,
        channelRaw: String,
        escalationRaw: String,
        message: String,
        requiresConfirmation: Bool,
        sequence: Int,
        offsetKind: String,
        offsetInterval: Double?,
        offsetDays: Int?,
        offsetHour: Int?,
        offsetMinute: Int?,
        offsetDate: Date?,
        stateRaw: String? = nil,
        stateChangedAt: Date? = nil,
        scheduledFor: Date? = nil
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.channelRaw = channelRaw
        self.escalationRaw = escalationRaw
        self.message = message
        self.requiresConfirmation = requiresConfirmation
        self.sequence = sequence
        self.offsetKind = offsetKind
        self.offsetInterval = offsetInterval
        self.offsetDays = offsetDays
        self.offsetHour = offsetHour
        self.offsetMinute = offsetMinute
        self.offsetDate = offsetDate
        self.stateRaw = stateRaw
        self.stateChangedAt = stateChangedAt
        self.scheduledFor = scheduledFor
    }
}

// MARK: - Settings and profile

/// Assistant settings. One logical record; see `SingletonRecord`.
///
/// The selected provider is stored here as an identifier, which is all it is.
/// **No credential is stored in SwiftData** — the API key lives in the Keychain
/// behind `CredentialStore`, and nothing in this file can reach it.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDAssistantSettings {
    @Attribute(.unique) public var id: UUID
    public var preferredProviderID: String?
    public var preferredModelID: String?
    public var routingPolicyRaw: String
    /// `ToolKind.rawValue` → `ToolAuthorization.rawValue`. Both sides are
    /// closed string enums, so this stays readable and migratable; it is a
    /// small fixed map, not a document.
    public var toolAuthorizations: [String: String]
    public var defaultAuthorizationRaw: String
    public var conversationContextLimit: Int
    public var memoryContextLimit: Int

    public var supportAdvanceNoticeDays: [Int]
    public var supportMorningOfHour: Int
    public var supportMorningOfMinute: Int
    public var supportPreparationLeadDefault: Double
    public var supportFinalCallLead: Double
    public var supportDefaultEscalationRaw: String
    public var supportFlexibleNudgesPerDay: Int

    public var supportFollowUpIsEnabled: Bool
    public var supportFollowUpMaximum: Int
    public var supportFollowUpInterval: Double
    public var supportFollowUpEscalatesEachTime: Bool

    public var supportSnoozeIsAllowed: Bool
    public var supportSnoozeDefaultDuration: Double
    public var supportSnoozeMaximum: Int
    public var supportSnoozeEscalateAfter: Int

    public var supportCompletionRequiresExplicitConfirmation: Bool
    public var supportCompletionMarkMissedAfter: Double?

    public init(
        id: UUID,
        preferredProviderID: String?,
        preferredModelID: String?,
        routingPolicyRaw: String,
        toolAuthorizations: [String: String],
        defaultAuthorizationRaw: String,
        conversationContextLimit: Int,
        memoryContextLimit: Int,
        supportAdvanceNoticeDays: [Int],
        supportMorningOfHour: Int,
        supportMorningOfMinute: Int,
        supportPreparationLeadDefault: Double,
        supportFinalCallLead: Double,
        supportDefaultEscalationRaw: String,
        supportFlexibleNudgesPerDay: Int,
        supportFollowUpIsEnabled: Bool,
        supportFollowUpMaximum: Int,
        supportFollowUpInterval: Double,
        supportFollowUpEscalatesEachTime: Bool,
        supportSnoozeIsAllowed: Bool,
        supportSnoozeDefaultDuration: Double,
        supportSnoozeMaximum: Int,
        supportSnoozeEscalateAfter: Int,
        supportCompletionRequiresExplicitConfirmation: Bool,
        supportCompletionMarkMissedAfter: Double?
    ) {
        self.id = id
        self.preferredProviderID = preferredProviderID
        self.preferredModelID = preferredModelID
        self.routingPolicyRaw = routingPolicyRaw
        self.toolAuthorizations = toolAuthorizations
        self.defaultAuthorizationRaw = defaultAuthorizationRaw
        self.conversationContextLimit = conversationContextLimit
        self.memoryContextLimit = memoryContextLimit
        self.supportAdvanceNoticeDays = supportAdvanceNoticeDays
        self.supportMorningOfHour = supportMorningOfHour
        self.supportMorningOfMinute = supportMorningOfMinute
        self.supportPreparationLeadDefault = supportPreparationLeadDefault
        self.supportFinalCallLead = supportFinalCallLead
        self.supportDefaultEscalationRaw = supportDefaultEscalationRaw
        self.supportFlexibleNudgesPerDay = supportFlexibleNudgesPerDay
        self.supportFollowUpIsEnabled = supportFollowUpIsEnabled
        self.supportFollowUpMaximum = supportFollowUpMaximum
        self.supportFollowUpInterval = supportFollowUpInterval
        self.supportFollowUpEscalatesEachTime = supportFollowUpEscalatesEachTime
        self.supportSnoozeIsAllowed = supportSnoozeIsAllowed
        self.supportSnoozeDefaultDuration = supportSnoozeDefaultDuration
        self.supportSnoozeMaximum = supportSnoozeMaximum
        self.supportSnoozeEscalateAfter = supportSnoozeEscalateAfter
        self.supportCompletionRequiresExplicitConfirmation = supportCompletionRequiresExplicitConfirmation
        self.supportCompletionMarkMissedAfter = supportCompletionMarkMissedAfter
    }
}

/// The user's profile. One logical record; see `SingletonRecord`.
///
/// Kept separate from memory because the domain keeps them separate: the
/// profile is a small set of structured fields planning code reads directly,
/// memory is an open-ended set of remembered statements.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDUserProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String?
    public var timeZoneIdentifier: String
    public var wakeHour: Int?
    public var wakeMinute: Int?
    public var sleepHour: Int?
    public var sleepMinute: Int?
    public var defaultPreparationDuration: Double
    public var defaultTravelDuration: Double
    public var quietHoursStartHour: Int?
    public var quietHoursStartMinute: Int?
    public var quietHoursEndHour: Int?
    public var quietHoursEndMinute: Int?

    public init(
        id: UUID,
        displayName: String?,
        timeZoneIdentifier: String,
        wakeHour: Int?,
        wakeMinute: Int?,
        sleepHour: Int?,
        sleepMinute: Int?,
        defaultPreparationDuration: Double,
        defaultTravelDuration: Double,
        quietHoursStartHour: Int?,
        quietHoursStartMinute: Int?,
        quietHoursEndHour: Int?,
        quietHoursEndMinute: Int?
    ) {
        self.id = id
        self.displayName = displayName
        self.timeZoneIdentifier = timeZoneIdentifier
        self.wakeHour = wakeHour
        self.wakeMinute = wakeMinute
        self.sleepHour = sleepHour
        self.sleepMinute = sleepMinute
        self.defaultPreparationDuration = defaultPreparationDuration
        self.defaultTravelDuration = defaultTravelDuration
        self.quietHoursStartHour = quietHoursStartHour
        self.quietHoursStartMinute = quietHoursStartMinute
        self.quietHoursEndHour = quietHoursEndHour
        self.quietHoursEndMinute = quietHoursEndMinute
    }
}

/// Fixed identifiers for the records the domain treats as singletons.
///
/// Settings and profile are one logical value each. Giving them a constant id
/// rather than "fetch the first row" means a fetch-or-create can never race
/// itself into two rows, and the uniqueness constraint enforces it in storage
/// rather than in a convention someone has to remember.
public enum SingletonRecord {
    public static let settings = UUID(uuidString: "5E771465-0000-4000-A000-000000000001")!
    public static let profile = UUID(uuidString: "5E771465-0000-4000-A000-000000000002")!
}

#endif
