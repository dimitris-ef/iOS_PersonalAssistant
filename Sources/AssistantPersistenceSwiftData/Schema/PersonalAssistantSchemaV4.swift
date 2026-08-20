#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 4: the assistant can be asked to talk back.
//
// V3 had no concept of voice at all. Speaking replies aloud is a preference
// that has to survive a relaunch like any other, and the settings row is where
// the app's preferences live — so `SDAssistantSettings` gains three columns:
// whether spoken replies are on, whether typed messages get them too, and which
// language to use.
//
// Only `SDAssistantSettings` changes, and only by gaining columns. The two
// booleans default to `false` in the model declaration, which is both what
// makes the migration inferrable and the right product default: someone who
// updates the app does not discover it by having it start speaking to them.
//
// The locale column is optional and nil means "follow the system", so an
// existing store needs nothing computed for it either.
//
// See the note in `PersonalAssistantSchemaV2` about how these versions share
// their model classes, and what must happen before a change that is *not*
// purely additive.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV4: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

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
