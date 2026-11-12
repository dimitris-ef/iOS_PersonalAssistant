import AssistantDomain
import SwiftUI

/// Every chat, most recently used first.
///
/// Build 20 had exactly one conversation, so when Apple's on-device model
/// said "start a new one" there was nowhere to go. Tasks, reminders and
/// memories are not stored in a chat, so switching or deleting one never
/// touches them.
///
/// Deleting (build 29): swipe left, long-press → Delete, or Edit to tick
/// several and delete them together. Build 28 had only the swipe, which
/// nobody could find.
struct ConversationsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var selection: Set<Conversation.ID> = []
    /// What the confirmation is about to delete.
    @State private var pendingDeletion: Set<Conversation.ID> = []

    var body: some View {
        NavigationStack {
            List {
                if !isEditing {
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

                        Button {
                            Task {
                                await model.startTemporaryConversation()
                                dismiss()
                            }
                        } label: {
                            Label("New Temporary Chat", systemImage: "eye.slash")
                        }
                        .disabled(model.isAssistantResponding)
                    } footer: {
                        Text("A temporary chat is never saved. Reminders, tasks and memories from it are kept.")
                    }
                }

                Section {
                    ForEach(model.conversations) { conversation in
                        Button {
                            if isEditing {
                                toggle(conversation.id)
                            } else {
                                Task {
                                    await model.openConversation(conversation.id)
                                    dismiss()
                                }
                            }
                        } label: {
                            row(for: conversation)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                pendingDeletion = [conversation.id]
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDeletion = [conversation.id]
                            } label: {
                                Label("Delete", systemImage: "trash")
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? "Cancel" : "Edit") {
                        isEditing.toggle()
                        selection = []
                    }
                    .disabled(model.conversations.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button("Delete (\(selection.count))", role: .destructive) {
                            pendingDeletion = selection
                        }
                        .disabled(selection.isEmpty)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task { await model.refreshConversations() }
            .confirmationDialog(
                pendingDeletion.count == 1 ? "Delete this chat?" : "Delete \(pendingDeletion.count) chats?",
                isPresented: Binding(
                    get: { !pendingDeletion.isEmpty },
                    set: { if !$0 { pendingDeletion = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = pendingDeletion
                    pendingDeletion = []
                    Task {
                        await model.deleteConversations(ids)
                        selection.subtract(ids)
                        if model.conversations.isEmpty { isEditing = false }
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = [] }
            } message: {
                Text("The messages are removed. Tasks, reminders and memories stay.")
            }
        }
    }

    private func toggle(_ id: Conversation.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func row(for conversation: Conversation) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            if isEditing {
                Image(systemName: selection.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(conversation.id) ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .accessibilityLabel(selection.contains(conversation.id) ? "Selected" : "Not selected")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                Text(conversation.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !isEditing, conversation.id == model.conversation.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Open now")
            }
        }
        .contentShape(Rectangle())
    }
}
