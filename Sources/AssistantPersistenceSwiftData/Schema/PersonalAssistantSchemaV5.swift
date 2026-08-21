#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 5: a failed action records which kind of failure it was.
//
// Up to V4 a tool result stored an outcome discriminator and a sentence. That
// is enough to badge a card red, and not enough to say anything useful about
// it: "Failed: the operation couldn't be completed" and "Calendar access is
// turned off, you can switch it back on in Settings" were the same row.
//
// `SDToolResult` therefore gains one nullable column, `failureRaw`, holding a
// `ToolFailureCategory` raw value. Nil means either "this succeeded" or "this
// was written before V5" — the mapper treats both the same way and falls back
// to the sentence, which every existing row already has.
//
// Only `SDToolResult` changes, and only by gaining an optional column, so the
// migration is inferrable. Nothing is recomputed and nothing is lost.
//
// See the note in `PersonalAssistantSchemaV2` about how these versions share
// their model classes, and what must happen before a change that is *not*
// purely additive.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV5: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

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
