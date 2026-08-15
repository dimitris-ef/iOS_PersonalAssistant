import AssistantDomain
import SwiftUI

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
                .sheet(isPresented: $viewModel.isShowingVoicePlaceholder) {
                    VoiceInputPlaceholderView()
                        .presentationDetents([.height(280)])
                        .presentationDragIndicator(.visible)
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

            AssistantComposerView(
                text: $viewModel.draft,
                isFocused: $isComposerFocused,
                canSend: viewModel.canSend,
                onSend: { Task { await viewModel.send(using: model) } },
                onVoice: { viewModel.isShowingVoicePlaceholder = true }
            )
        }
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.sm)
        .background(.bar)
        .animation(Theme.transition, value: isComposerFocused)
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
private struct AssistantHeaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 1) {
            Text("Assistant")
                .font(.headline)
            Text(AppFormatters.shared.fullDate(model.now))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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
