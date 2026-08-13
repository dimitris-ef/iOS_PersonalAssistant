// TODO-XCODE: this file is part of the iOS app target, not the Swift package.
// It does not compile during Windows-stage development.

import AssistantCore
import SwiftUI

@main
struct PersonalAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            // TODO-XCODE: build the engine once and inject it, rather than
            // constructing it in the view.
            ConversationView()
        }
    }
}
