#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 10: the dedicated action model.
//
// Two columns on `SDAssistantSettings`, and the pair is the whole change:
//
//  1. `selectedActionModelID` — which installed local model interprets phone
//     actions.
//  2. `actionModelEnabled` — whether the dedicated action path may run.
//
// ## Why this is not `selectedLocalModelID`
//
// Part 3, section 1. `selectedLocalModelID` is the model the user chose to
// *talk to*. This is the model the app uses to *understand a request to do
// something*. Reusing the first for the second is exactly the coupling Parts 1
// and 2 removed — it would mean picking a chat model silently decided whether
// the phone could be operated, and picking Apple's on-device model or a remote
// provider would leave the action path with nothing at all.
//
// ## What an existing store becomes
//
// `selectedActionModelID` is nil: **no action model chosen**. Deliberately not
// "inherit whatever the chat model was". An upgrading user has never been asked
// this question, and answering it for them by pointing the action system at a
// 3B chat model — which may not even be installed — would be the app inventing
// a preference. Nil resolves to "unavailable, choose a model", which the
// Settings screen says plainly and the action path fails safely on.
//
// `actionModelEnabled` defaults to true, so the feature is not switched off for
// everyone who upgrades. With no model selected that still means unavailable;
// the flag exists so "I have not chosen yet" and "I turned this off" stay
// different states.
//
// ## Why lightweight
//
// One nullable column and one non-optional column with a declared default,
// which is the pair of shapes SwiftData can infer. Nothing is computed from old
// data and nothing is dropped.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV10: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(10, 0, 0) }

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

#endif
