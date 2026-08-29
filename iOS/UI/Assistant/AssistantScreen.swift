import AIProviderLocal
import AssistantDomain
import AssistantVoice
import SwiftUI
import UIKit

/// The main screen: a conversation that produces real, structured results.
///
/// It is deliberately not a messenger. Assistant replies sit in the page rather
/// than in bubbles, and what the assistant *did* is shown as a card beneath
/// what it said — because in this product the actions are the point.
struct AssistantScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel = AssistantViewModel()
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationStack {
            conversation
                .background(Color(.systemBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) { composerArea }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { AssistantHeaderView() }
                    ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton() }
                }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if let notice = providerNotice {
                        ProviderNoticeView(text: notice)
                    }

                    ForEach(viewModel.turns(for: model)) { turn in
                        ConversationTurnView(turn: turn)
                            .id(turn.id)
                    }

                    if model.isAssistantResponding {
                        TypingIndicatorView()
                            .id(Self.typingIndicatorID)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.conversation.messages.count) {
                guard let last = model.conversation.messages.last?.id else { return }
                withAnimation(Theme.transition) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onChange(of: model.isAssistantResponding) { _, isResponding in
                guard isResponding else { return }
                withAnimation(Theme.transition) {
                    proxy.scrollTo(Self.typingIndicatorID, anchor: .bottom)
                }
            }
            .onAppear {
                guard let last = model.conversation.messages.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private static let typingIndicatorID = "assistant-typing"

    // MARK: Composer

    @ViewBuilder
    private var composerArea: some View {
        VStack(spacing: Theme.Spacing.md) {
            if viewModel.showsSuggestions(for: model.conversation) && !isComposerFocused {
                SuggestedPromptsView { prompt in
                    viewModel.applySuggestion(prompt)
                    isComposerFocused = true
                }
                .transition(.opacity)
            }

            // The composer becomes the voice UI while the microphone is
            // live, rather than a sheet appearing over the conversation. The
            // user is mid-conversation and should stay in it — and it means
            // there is exactly one place that can be typing *or* speaking,
            // never both.
            if let voice = model.voice, voice.state != .idle, voice.state != .speaking {
                VoiceComposerView(
                    state: voice.state,
                    onStop: { voice.stopListening() },
                    onCancel: { voice.cancelListening() },
                    onRetry: { voice.retry() },
                    onDismissError: { voice.dismissError() },
                    onOpenSettings: { openSystemSettings() }
                )
                .transition(.opacity)
            } else {
                AssistantComposerView(
                    text: $viewModel.draft,
                    isFocused: $isComposerFocused,
                    canSend: viewModel.canSend,
                    isVoiceAvailable: model.isVoiceAvailable,
                    isSpeaking: model.voice?.state == .speaking,
                    onSend: { Task { await viewModel.send(using: model) } },
                    onVoice: { model.voice?.startListening() },
                    onStopSpeaking: { Task { await model.voice?.stopSpeaking() } }
                )
            }
        }
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.sm)
        .background(.bar)
        .animation(Theme.transition, value: isComposerFocused)
        .animation(Theme.quickTransition, value: model.voice?.state)
    }

    /// Opens the app's own page in Settings.
    ///
    /// Only ever from a button the user pressed. The app never navigates here
    /// on its own — being ejected into Settings because a permission was
    /// missing is a context switch nobody asked for.
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Says plainly when the chosen model cannot actually answer.
    ///
    /// Absent entirely once a real model is configured — a working assistant
    /// should not carry a permanent disclaimer.
    private var providerNotice: String? {
        guard let option = model.selectedProviderOption, !option.isAvailable else { return nil }

        if option.needsConfiguration {
            return "\(option.metadata.displayName) needs setting up, so replies come from a development stand-in. Configure it in Settings."
        }
        return "\(option.metadata.displayName) isn't available yet, so replies come from a development stand-in."
    }
}

/// The header: identity, and today's date for context.
/// The title, and underneath it what will answer the next message.
///
/// The picker lives here rather than above the composer for a reason: it is a
/// statement about the whole conversation, not about the message being typed,
/// and putting it by the text field invites the reading that it applies to one
/// send. It is a caption-sized menu — visible without competing with the
/// conversation (section 20).
private struct AssistantHeaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 1) {
            Text("Assistant")
                .font(.headline)
            AssistantModelMenu()
        }
        .task { await model.refreshAssistantChoices() }
    }
}

/// Which provider and model answers, as a menu.
private struct AssistantModelMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.assistantChoices) { choice in
                Button {
                    Task { await model.selectAssistantChoice(choice) }
                } label: {
                    // A checkmark rather than a highlight: the menu is read at
                    // a glance and "which one is on" has to survive that.
                    if isActive(choice) {
                        Label(label(for: choice), systemImage: "checkmark")
                    } else {
                        Text(label(for: choice))
                    }
                }
            }
            if model.assistantChoices.isEmpty {
                Text("No model is available")
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Assistant model")
        .accessibilityValue(currentTitle)
    }

    /// Never a bare "Local AI": with three models downloaded that names a
    /// category, not an answer (section 23).
    private var currentTitle: String {
        model.activeAssistantChoice?.title ?? "Choose a model"
    }

    private func isActive(_ choice: AssistantModelChoice) -> Bool {
        model.activeAssistantChoice == choice
    }

    private func label(for choice: AssistantModelChoice) -> String {
        guard let subtitle = choice.subtitle else { return choice.title }
        return "\(choice.title) — \(subtitle)"
    }
}

private struct ProviderNoticeView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            )
    }
}

/// Three dots while a turn is in flight. The composer stays usable throughout.
private struct TypingIndicatorView: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == index ? 1 : 0.3)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityLabel("Assistant is thinking")
        .task {
            // A plain repeating tick rather than a spring, so it reads as
            // patient instead of busy.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(Theme.quickTransition) { phase = (phase + 1) % 3 }
            }
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    AssistantScreen()
        .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
