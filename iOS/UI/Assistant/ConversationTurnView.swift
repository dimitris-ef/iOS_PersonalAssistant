import AssistantDomain
import SwiftUI

/// One message, plus whatever the assistant did as a result of it.
struct ConversationTurnView: View {
    let turn: AssistantViewModel.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            switch turn.message.role {
            case .user:
                UserMessageView(message: turn.message)
            case .assistant:
                AssistantMessageView(message: turn.message)
            case .system:
                SystemNoteView(message: turn.message)
            }

            if !turn.actions.isEmpty {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(turn.actions) { action in
                        AssistantActionCardView(action: action)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity
        ))
    }
}

/// The user's own words, grouped in a bubble so the transcript reads clearly.
struct UserMessageView: View {
    let message: Message

    var body: some View {
        HStack {
            Spacer(minLength: Theme.Spacing.xxl)
            Text(message.text)
                .font(.body)
                .foregroundStyle(Color.white)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    Color.accentColor,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                )
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said: \(message.text)")
    }
}

/// The assistant's reply.
///
/// No bubble: the assistant is the voice of the app, so its words sit in the
/// page. That also stops a screen full of results from looking like a chat log.
struct AssistantMessageView: View {
    let message: Message

    var body: some View {
        Text(message.text)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityLabel("Assistant said: \(message.text)")
    }
}

/// An application-authored note, e.g. "reminder snoozed". Quiet by design —
/// it is a record, not something the assistant said.
struct SystemNoteView: View {
    let message: Message

    var body: some View {
        Label(message.text, systemImage: "circle.dotted")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Messages") {
    // TODO-XCODE: Verify SwiftUI preview.
    let now = Date()
    return ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            UserMessageView(
                message: Message(role: .user, text: "I have a haircut Sunday at 10 PM.", createdAt: now)
            )
            AssistantMessageView(
                message: Message(
                    role: .assistant,
                    text: "Got it. I've added your haircut for Sunday at 10 PM, and I'll nudge you along the way.",
                    createdAt: now
                )
            )
        }
        .padding()
    }
}
