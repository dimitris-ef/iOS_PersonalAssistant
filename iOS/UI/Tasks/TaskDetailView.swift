import AssistantDomain
import SwiftUI

/// Everything about one task, and everything you can do to it.
///
/// The status section is deliberately explicit: "Reminded" and "Needs
/// follow-up" are shown with a plain-English explanation, because the whole
/// point is that they are *not* the same as done.
struct TaskDetailView: View {
    let taskID: TaskItem.ID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingEditor = false
    @State private var isConfirmingDelete = false

    private var task: TaskItem? { model.task(id: taskID) }

    var body: some View {
        Group {
            if let task {
                content(for: task)
            } else {
                EmptyStateView(
                    systemImage: "questionmark.circle",
                    title: "Task not found",
                    message: "It may have been deleted."
                )
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func content(for task: TaskItem) -> some View {
        let presenter = TaskPresenter(now: model.now, calendar: model.calendar)

        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(task.title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if let details = task.details {
                        Text(details)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            Section("Status") {
                LabeledContent("Status") {
                    TaskStatusBadge(status: task.status)
                }
                if let explanation = TaskPresenter.explanation(for: task.status) {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Priority", value: ImportanceStyle.label(for: task.importance))
                LabeledContent("When", value: presenter.timingLabel(for: task))
                if task.snoozeCount > 0 {
                    LabeledContent("Snoozed", value: "\(task.snoozeCount) times")
                }
                if task.followUpCount > 0 {
                    LabeledContent("Followed up", value: "\(task.followUpCount) times")
                }
                if let next = nextFollowUp(for: task) {
                    // The answer to "why am I being reminded about this again?",
                    // stated before the user has to ask it. Support the user
                    // cannot see is indistinguishable from nagging.
                    LabeledContent(
                        "Next check-in",
                        value: AppFormatters.shared.relativeDayAndTime(next, now: model.now)
                    )
                }
            }

            if let plan = model.reminderPlan(forTask: task.id) {
                reminderSection(plan: plan)
            }

            Section {
                if task.status == .completed {
                    Button {
                        Task { await model.reopenTask(task.id) }
                    } label: {
                        Label("Reopen", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        Task { await model.completeTask(task.id) }
                    } label: {
                        Label("Mark complete", systemImage: "checkmark.circle")
                    }

                    if task.status != .inProgress {
                        Button {
                            Task { await model.startTask(task.id) }
                        } label: {
                            Label("I'm working on it", systemImage: "circle.lefthalf.filled")
                        }
                    }

                    Button {
                        Task { await model.snoozeTask(task.id) }
                    } label: {
                        Label("Snooze 10 minutes", systemImage: "moon.zzz")
                    }
                }

                Button {
                    isShowingEditor = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $isShowingEditor) {
            NavigationStack {
                TaskEditorView(task: task)
            }
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteTask(task.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    /// When the assistant next intends to come back, if it does.
    private func nextFollowUp(for task: TaskItem) -> Date? {
        guard !task.status.isTerminal else { return nil }
        return model.reminderPlan(forTask: task.id)?.nextPendingStage?.scheduledFor
    }

    @ViewBuilder
    private func reminderSection(plan: ReminderPlan) -> some View {
        let presentation = ReminderPlanPresentation.make(
            from: plan,
            now: model.now,
            calendar: model.calendar
        )

        Section {
            ReminderTimelineView(plan: presentation) { stage in
                simulate(stage: stage, plan: plan)
            }
            .padding(.vertical, Theme.Spacing.sm)
        } header: {
            Text("Reminder plan")
        } footer: {
            if let followUp = presentation.followUpSummary {
                Text(followUp)
            }
        }
    }

    private func simulate(stage: ReminderPlanPresentation.Stage, plan: ReminderPlan) {
        guard let domainStage = plan.stages.first(where: { $0.id == stage.id }) else { return }
        model.simulateReminder(
            for: SimulatedReminder.from(
                stage: domainStage,
                plan: plan,
                anchor: plan.subject.anchor.date ?? stage.fireDate,
                formatter: AppFormatters.shared
            )
        )
        dismiss()
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    let model = AppModel(environment: AppEnvironment.makeDemo())
    return NavigationStack {
        TaskDetailView(taskID: .init())
    }
    .environment(model)
}
