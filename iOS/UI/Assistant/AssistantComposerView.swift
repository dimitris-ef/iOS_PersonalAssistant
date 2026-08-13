import SwiftUI

/// The main interaction area: type or speak to the assistant.
struct AssistantComposerView: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let canSend: Bool
    let onSend: () -> Void
    let onVoice: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            Button(action: onVoice) {
                Image(systemName: "mic")
                    .font(.body)
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Voice input")

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

/// The microphone placeholder.
///
/// Voice is a real intention, not a real feature yet — so the button exists and
/// says exactly that, rather than showing a fake waveform.
///
/// TODO-XCODE: implement with `AVAudioEngine` for capture and `SFSpeechRecognizer`
/// (or on-device dictation) for transcription. Both need a device, microphone
/// and speech-recognition usage descriptions, and neither can be built or
/// tested from Windows.
struct VoiceInputPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "mic")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.top, Theme.Spacing.xxl)

            Text("Voice isn't wired up yet")
                .font(.headline)

            Text("Speaking to the assistant needs microphone capture and speech recognition, which arrive with the Apple integration. For now, type instead.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)

            Button("OK") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, Theme.Spacing.sm)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
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
