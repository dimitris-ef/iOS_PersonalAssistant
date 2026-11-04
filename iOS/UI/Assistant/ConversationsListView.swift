import AssistantDomain
import SwiftUI

/// Every chat, most recently used first.
///
/// Build 20 had exactly one conversation, so when Apple's on-device model
/// said "start a new one" there was nowhere to go. Tasks, reminders and
/// memories are not stored in a chat, so switching or deleting one never
/// touches them.
struct ConversationsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: Conversation?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            await model.startNewConversation()
                            dismiss()
                        }
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .disabled(model.isAssistantResponding)
                }

                Section {
                    ForEach(model.conversations) { conversation in
                        Button {
                            Task {
                                await model.openConversation(conversation.id)
                                dismiss()
                            }
                        } label: {
                            row(for: conversation)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                pendingDeletion = conversation
                            }
                        }
                    }
                } footer: {
                    Text("Deleting a chat keeps the tasks, reminders and memories it created.")
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.refreshConversations() }
            .confirmationDialog(
                "Delete this chat?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let pending = pendingDeletion else { return }
                    pendingDeletion = nil
                    Task { await model.deleteConversation(pending.id) }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("The messages are removed. Tasks, reminders and memories stay.")
            }
        }
    }

    private func row(for conversation: Conversation) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                Text(conversation.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if conversation.id == model.conversation.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Open now")
            }
        }
        .contentShape(Rectangle())
    }
}
