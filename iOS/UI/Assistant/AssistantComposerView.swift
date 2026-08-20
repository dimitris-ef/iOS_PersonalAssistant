import SwiftUI

/// The main interaction area: type or speak to the assistant.
struct AssistantComposerView: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let canSend: Bool
    /// False where speech recognition does not exist. The button is shown
    /// disabled rather than hidden, so the capability is discoverable and its
    /// absence is explained rather than silent.
    var isVoiceAvailable: Bool = true
    /// True while the assistant is reading a reply aloud.
    var isSpeaking: Bool = false
    let onSend: () -> Void
    let onVoice: () -> Void
    var onStopSpeaking: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            // While the assistant is talking, the same button stops it. Tapping
            // a microphone during playback means "my turn" either way, and the
            // coordinator's own rule — stop speaking, then listen — makes the
            // two readings converge.
            Button(action: isSpeaking ? onStopSpeaking : onVoice) {
                Image(systemName: isSpeaking ? "stop.circle" : "mic")
                    .font(.body)
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isVoiceAvailable ? .secondary : Color(.tertiaryLabel))
            .disabled(!isVoiceAvailable)
            .accessibilityLabel(isSpeaking ? "Stop speaking" : "Voice input")
            .accessibilityHint(isVoiceAvailable ? "" : "Speech recognition isn't available on this device")

            // `axis: .vertical` grows the field with the text, up to the line
            // limit, which is what a composer should do on a phone.
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(.body)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 10)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                )
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit { if canSend { onSend() } }
                .accessibilityLabel("Message the assistant")

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.35)
            .animation(Theme.quickTransition, value: canSend)
            .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            .accessibilityLabel("Send")
            // Sending stays available while a reply is in flight; the assistant
            // being busy should never lock the person out of the composer.
        }
        .padding(.horizontal, Theme.Spacing.md)
    }
}

/// Quick ways in, shown while the conversation is still short.
struct SuggestedPromptsView: View {
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(DemoData.suggestedPrompts, id: \.self) { prompt in
                    Button {
                        onSelect(prompt)
                    } label: {
                        Text(prompt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(
                                Capsule().strokeBorder(Color(.separator), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Suggested prompts")
    }
}

#Preview("Composer") {
    // TODO-XCODE: Verify SwiftUI preview.
    struct Harness: View {
        @State private var text = ""
        @FocusState private var focused: Bool

        var body: some View {
            VStack {
                Spacer()
                SuggestedPromptsView { text = $0 }
                AssistantComposerView(
                    text: $text,
                    isFocused: $focused,
                    canSend: !text.isEmpty,
                    onSend: { text = "" },
                    onVoice: {}
                )
            }
            .padding(.vertical)
        }
    }
    return Harness()
}
