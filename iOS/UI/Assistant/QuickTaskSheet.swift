import SwiftUI

/// Quick Task: one sentence, straight to the action model, no chat kept.
///
/// For "remind me at 6 to call mum" when there is nothing to talk about. The
/// reminder, task or event is created exactly as from a chat; the sentence
/// itself is not stored anywhere, so chats stay for conversation.
struct QuickTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var outcome: (message: String, succeeded: Bool)?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Remind me in 10 minutes to…",
                        text: $text,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(perform)
                    .disabled(model.isPerformingQuickTask)
                } footer: {
                    Text(
                        "A reminder, task, event or something to remember. It's done by the "
                            + "action model and isn't kept as a chat. Tap the microphone on "
                            + "the keyboard to say it."
                    )
                }

                if model.isPerformingQuickTask {
                    Section {
                        HStack(spacing: Theme.Spacing.sm) {
                            ProgressView()
                            Text("Working on it…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let outcome {
                    Section {
                        Label {
                            Text(outcome.message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(
                                systemName: outcome.succeeded
                                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)
                        }
                    }
                }
            }
            .navigationTitle("Quick Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Do It", action: perform)
                        .disabled(
                            model.isPerformingQuickTask
                                || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func perform() {
        let sentence = text
        guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            guard let result = await model.performQuickTask(sentence) else { return }
            outcome = result
            // Cleared only when it worked, so a sentence that failed can be
            // fixed rather than typed again.
            if result.succeeded { text = "" }
            isFocused = true
        }
    }
}
