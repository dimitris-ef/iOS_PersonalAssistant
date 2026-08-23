#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 9: background reliability.
//
// Three additions, one theme — being able to reconstruct, after the process has
// been gone, exactly what support the user is owed and what the operating
// system currently believes.
//
//  1. `SDReminderStage` gains five delivery columns: whether iOS holds a
//     request for this stage, when the app last asked, how many times, why it
//     last failed, and under which plan revision it was scheduled.
//
//  2. `SDReminderPlan` gains `revision`. A reminder handed to iOS is a promise
//     made at a moment in time, and the plan can move underneath it. The
//     revision is what makes a callback from an obsolete notification
//     recognisable rather than silently destructive.
//
//  3. `SDHandledAction`, a new entity. One row per support action already
//     applied, so a notification callback delivered twice — which real ones are
//     — changes the world once.
//
// ## Why delivery state is not folded into `stateRaw`
//
// Because they answer different questions, and section 12 turns on the
// distinction: `stateRaw` is what became of the reminder as far as the user is
// concerned (delivered, dismissed, snoozed, missed), and the delivery columns
// are whether the OS was ever successfully asked to deliver it. A stage that
// could not be scheduled because notification permission is off is `pending`
// and undelivered. One column would force it to choose between lying and
// destroying its own lifecycle.
//
// ## Why the handled-action table is separate from the tool ledger
//
// Section 53 asks for reuse where it fits cleanly. The Part 7 execution ledger
// is turn-scoped and in memory — its job is stopping one agent loop repeating
// itself inside one turn. A duplicate notification callback arrives with no
// turn in sight, often in a process that has just launched to handle it, and
// possibly minutes later. Nothing in-memory can see that.
//
// ## Why it is bounded
//
// `SDHandledAction` rows are pruned by age. An action from six months ago
// cannot arrive again, and a table that only ever grows is a table that
// eventually costs a launch.
//
// ## Why this stays inferrable
//
// Every added property is optional or carries a declared default, and the one
// new model is a new entity — the case SwiftData resolves from the store's own
// metadata. See `PersonalAssistantSchemaV2` for what would make it not be.
//
// ## What an existing store becomes
//
// Every plan is at revision 1 and every stage is `planned` — meaning "the app
// has no record of having scheduled this". That is the truth rather than a
// downgrade, and it is also the safe direction: the first reconciliation pass
// after upgrading finds the desired schedule missing, compares it against what
// iOS actually holds, and only adds what is genuinely absent.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV9: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            SDConversation.self,
            SDMessage.self,
            SDActionPlan.self,
            SDAction.self,
            SDToolResult.self,
            SDMemory.self,
            SDMemoryRelation.self,
            SDMemoryEmbedding.self,
            SDTask.self,
            SDRoutine.self,
            SDReminderPlan.self,
            SDReminderStage.self,
            SDAssistantSettings.self,
            SDUserProfile.self,
            SDLocalModel.self,
            SDHandledAction.self,
        ]
    }
}

/// One support action that has already been applied.
///
/// Keyed by an identifier derived from the stage, the action and the plan
/// revision — never allocated. That is what makes the check work across a
/// relaunch: the same callback arriving in a different process computes the
/// same identifier and finds the row already there.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDHandledAction {
    /// Derived from (stage, action, revision). Unique, which is what turns
    /// "have I already done this?" into an index lookup rather than a scan.
    @Attribute(.unique) public var id: UUID
    public var stageID: UUID
    public var taskID: UUID
    /// The outcome's raw value. A string rather than an enum column so a
    /// payload written by a newer build does not make an older one fail to
    /// decode a row it merely needs to skip.
    public var action: String
    /// The plan revision the action was applied under. Part of the identity:
    /// a snooze at revision 3 and a snooze at revision 4 are two different
    /// actions, because the plan changed in between.
    public var revision: Int
    /// When it was applied. The column `prune(before:)` sweeps on.
    public var handledAt: Date

    public init(
        id: UUID,
        stageID: UUID,
        taskID: UUID,
        action: String,
        revision: Int,
        handledAt: Date
    ) {
        self.id = id
        self.stageID = stageID
        self.taskID = taskID
        self.action = action
        self.revision = revision
        self.handledAt = handledAt
    }
}

#endif
