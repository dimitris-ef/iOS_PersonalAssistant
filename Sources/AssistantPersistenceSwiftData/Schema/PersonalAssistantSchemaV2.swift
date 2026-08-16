#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 2: reminder stages remember what became of them.
//
// V1 stored a stage as a template — fire this many minutes before the anchor —
// with no record of whether it was delivered, dismissed or ignored. That made
// follow-up impossible to persist: the app could decide a reminder had been
// dismissed but had nowhere to write it down, so the knowledge died with the
// process.
//
// Only `SDReminderStage` changes: three optional properties are added.
//
// ## An honest note about how these two versions relate
//
// Both versions list the *same* Swift classes. Strictly, a `VersionedSchema`
// is meant to be a frozen snapshot of the model definitions as they were, which
// would mean copying all eleven models into a V2 namespace and leaving V1's
// copies untouched. Apple's pattern for that is nesting the `@Model` classes
// inside each version's enum, so both versions' copies keep the same entity
// name while being different Swift types.
//
// This schema was not written that way, and retrofitting it is a large change
// to make alongside a behavioural one. It is sound *for this migration* because
// the change is purely additive and every new property is optional: SwiftData
// infers the migration from the store's own recorded metadata, not from V1's
// Swift declaration, and adding nullable columns is the case inference handles.
//
// It will not be sound for a change that renames, retypes or removes anything.
// **Before V3, if that change is not purely additive, nest the models per
// version first.** That refactor is mechanical; doing it under pressure with
// real user data on disk is not.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

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

#endif
