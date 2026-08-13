// TODO-XCODE: this file is part of the iOS app target, not the Swift package.
// It does not compile during Windows-stage development.

import AssistantDomain
import AssistantCore
import AssistantTools
import SwiftUI

/// The main conversation screen.
///
/// Sketched only to show the intended split: the view holds no assistant logic
/// and talks to `AssistantEngine` through one method. The action plan is shown
/// alongside the reply because the user needs to see what was actually done —
/// especially when the platform layer reports `.simulated` or an action is
/// waiting on their approval.
struct ConversationView: View {
    @State private var draft: String = ""
    @State private var messages: [Message] = []
    @State private var lastPlan: AssistantActionPlan?
    @State private var lastResults: [ToolResult] = []

    var body: some View {
        VStack {
            List(messages) { message in
                // TODO-XCODE: proper message styling, plan cards, confirmation
                // buttons for actions with `.requiresConfirmation`.
                Text(message.text)
            }

            HStack {
                TextField("Tell me about it…", text: $draft)
                Button("Send") {
                    // TODO-XCODE: call AssistantEngine.send(_:in:) and update
                    // messages, lastPlan and lastResults from the turn result.
                }
            }
            .padding()
        }
    }
}
