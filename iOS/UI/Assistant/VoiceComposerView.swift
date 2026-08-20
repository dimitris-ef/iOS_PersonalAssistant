import AssistantVoice
import SwiftUI

/// What the composer becomes while the microphone is on.
///
/// ## Design intent
///
/// Deliberately not a full-screen Siri orb. The user is in a conversation and
/// should stay in it: the composer grows, shows what is being heard, and offers
/// the two decisions that exist. Taking over the screen to record one sentence
/// makes a small act feel like a mode, and modes are exactly what an app for
/// people with executive-function difficulty should have fewer of.
///
/// The one thing that is not subtle is whether the microphone is live. That is
/// the whole point of §13, and the level meter only animates when there is
/// signal — a waveform that dances at silence is decoration pretending to be
/// feedback.
struct VoiceComposerView: View {
    let state: VoiceState
    let onStop: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismissError: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            switch state {
            case .requestingPermission:
                status("Checking microphone access…", systemImage: "mic")

            case .listening(let transcript, let level):
                listening(transcript: transcript, level: level)

            case .finalizing(let transcript):
                status("Finishing up…", systemImage: "waveform")
                transcriptText(transcript, isDim: true)

            case .processing(let transcript):
                status("Thinking…", systemImage: "ellipsis.bubble")
                transcriptText(transcript, isDim: true)

            case .failed(let error):
                failure(error)

            case .idle, .speaking:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        )
        .padding(.horizontal, Theme.Spacing.md)
        .animation(Theme.quickTransition, value: state)
    }

    // MARK: Pieces

    @ViewBuilder
    private func listening(transcript: String, level: Float) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            AudioLevelView(level: level)
            Text("Listening…")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        // One accessibility announcement covers what the meter conveys
        // visually. Someone using VoiceOver has to know the microphone is live
        // just as much as someone watching it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening")

        if transcript.isEmpty {
            Text("Go ahead — I'm listening.")
                .font(.body)
                .foregroundStyle(.tertiary)
        } else {
            transcriptText(transcript, isDim: false)
        }

        HStack(spacing: Theme.Spacing.sm) {
            // Cancel first, and visually quieter. Stop is the common action;
            // Cancel is the one you want when you have changed your mind, and
            // putting the destructive-feeling choice under your thumb by
            // default invites the wrong tap.
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .accessibilityHint("Discards what you said")

            Button("Stop", action: onStop)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Finishes and sends what you said")

            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func failure(_ error: VoiceError) -> some View {
        Label(error.message, systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)

        HStack(spacing: Theme.Spacing.sm) {
            if error.isRetryable {
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
            if error.isResolvableInSettings {
                // Offered, never performed automatically. Throwing someone out
                // of the app into Settings because a permission was missing is
                // a context switch they did not ask for.
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.bordered)
            }
            Button("Dismiss", action: onDismissError)
                .buttonStyle(.borderless)

            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }

    private func status(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func transcriptText(_ text: String, isDim: Bool) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(isDim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Partial results change several times a second; without this the
            // composer jitters as the recogniser revises itself.
            .animation(nil, value: text)
            .accessibilityLabel("Heard so far: \(text)")
    }
}

/// A five-bar level meter.
///
/// Presentation only: recognition works identically whether or not this exists,
/// and nothing about it is persisted. It is here because "is it hearing me?" is
/// the first question anyone asks of a microphone, and a static icon does not
/// answer it.
struct AudioLevelView: View {
    let level: Float

    private static let bars = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(isLit(index) ? Color.accentColor : Color(.tertiaryLabel))
                    .frame(width: 3, height: height(index))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func isLit(_ index: Int) -> Bool {
        Float(index) / Float(Self.bars) < level
    }

    /// A gentle arch, so the meter reads as a voice rather than a bar chart.
    private func height(_ index: Int) -> CGFloat {
        let distance = abs(Double(index) - Double(Self.bars - 1) / 2)
        let base = 16 - distance * 3
        return max(4, base)
    }
}

#Preview("Listening") {
    // TODO-XCODE: Verify SwiftUI preview.
    VStack(spacing: Theme.Spacing.lg) {
        VoiceComposerView(
            state: .listening(transcript: "Remind me tomorrow at ten to call the", level: 0.6),
            onStop: {}, onCancel: {}, onRetry: {}, onDismissError: {}, onOpenSettings: {}
        )
        VoiceComposerView(
            state: .processing(transcript: "Remind me tomorrow at ten to call the dentist."),
            onStop: {}, onCancel: {}, onRetry: {}, onDismissError: {}, onOpenSettings: {}
        )
        VoiceComposerView(
            state: .failed(.microphonePermissionDenied),
            onStop: {}, onCancel: {}, onRetry: {}, onDismissError: {}, onOpenSettings: {}
        )
        VoiceComposerView(
            state: .failed(.noSpeechDetected),
            onStop: {}, onCancel: {}, onRetry: {}, onDismissError: {}, onOpenSettings: {}
        )
    }
}
