#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 3: memories record how much they are trusted.
//
// V2 stored what a memory said, how important it was and where it came from,
// but not how sure the application was that it was true. Ranking needs that
// separately from salience: "my girlfriend's name is Anna" is near-certain and
// rarely relevant, while "probably prefers evening workouts" — inferred from a
// handful of observations — is worth acting on and might be wrong.
//
// Only `SDMemory` changes, and only by gaining one nullable column. See the
// note in `PersonalAssistantSchemaV2` about how these versions relate and what
// has to happen before a change that is not purely additive.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

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
