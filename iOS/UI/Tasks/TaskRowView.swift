import AssistantDomain
import SwiftUI

/// One task in the list.
struct TaskRowView: View {
    let task: TaskPresentation
    let onOpen: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isCompleted ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark as not done" : "Mark as done")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(task.title)
                            .font(.body)
                            .foregroundStyle(task.isCompleted ? .secondary : .primary)
                            .strikethrough(task.isCompleted, color: .secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if let tint = ImportanceStyle.tint(for: task.importance) {
                            Image(systemName: "flag.fill")
                                .font(.caption2)
                                .foregroundStyle(tint)
                                .accessibilityLabel(
                                    "\(ImportanceStyle.label(for: task.importance)) priority"
                                )
                        }
                    }

                    HStack(spacing: Theme.Spacing.sm) {
                        Text(task.timingLabel)
                            .foregroundStyle(task.isOverdue ? Color.orange : Color.secondary)

                        if let reminder = task.reminderLabel {
                            Text("·").foregroundStyle(.tertiary)
                            Text(reminder).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)

                    // The finer domain state, surfaced only when it says
                    // something the timing line does not.
                    if task.needsAttention || task.status == .snoozed {
                        TaskStatusBadge(status: task.status)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

/// A small pill for a task's current state.
struct TaskStatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Label {
            Text(TaskPresenter.label(for: status))
        } icon: {
            Image(systemName: TaskStatusStyle.symbol(for: status))
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(TaskStatusStyle.tint(for: status))
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(TaskStatusStyle.tint(for: status).opacity(0.12))
        )
        .labelStyle(.titleAndIcon)
    }
}

#Preview("Task rows") {
    // TODO-XCODE: Verify SwiftUI preview.
    List {
        TaskRowView(
            task: TaskPresentation(
                id: .init(),
                title: "Pay electricity bill",
                status: .reminded,
                statusLabel: "Reminded",
                importance: .high,
                timingLabel: "Due today · 9:00 PM",
                reminderLabel: "Next reminder 6:00 pm",
                isOverdue: false,
                isCompleted: false,
                needsAttention: false
            ),
            onOpen: {},
            onToggle: {}
        )
        TaskRowView(
            task: TaskPresentation(
                id: .init(),
                title: "Renew the gym membership",
                status: .needsFollowUp,
                statusLabel: "Needs follow-up",
                importance: .normal,
                timingLabel: "Due in 5 days",
                reminderLabel: nil,
                isOverdue: false,
                isCompleted: false,
                needsAttention: true
            ),
            onOpen: {},
            onToggle: {}
        )
    }
}
