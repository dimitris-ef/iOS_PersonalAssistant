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

            routineSection(for: task)
            dependencySection(for: task)
            preparationSection(for: task)

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

                        // The other half of starting: for the person who has
                        // not begun and cannot work out how to. It produces a
                        // first step, not a pep talk, and it does not complete
                        // anything.
                        Button {
                            Task { await model.helpMeStart(task.id) }
                        } label: {
                            Label("Help me start", systemImage: "play.circle")
                        }
                    }

                    if task.isRoutineOccurrence {
                        // Skipping today, not calling off the routine. The
                        // wording matters: "Cancel" here would read as ending
                        // the whole thing, which is not what anybody means by
                        // "not today".
                        Button {
                            Task { await model.skipOccurrence(task.id) }
                        } label: {
                            Label("Skip just this one", systemImage: "forward.end")
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

    /// What this occurrence repeats as, when it is one.
    ///
    /// Stated in words rather than shown as an editable rule, because the thing
    /// a person wants to check here is "is this the daily one or a one-off" —
    /// and because editing the schedule from inside one morning's occurrence
    /// would change every future morning without saying so.
    @ViewBuilder
    private func routineSection(for task: TaskItem) -> some View {
        if let routine = model.routine(forTask: task) {
            Section("Routine") {
                Text(routine.recurrence.summary(calendar: model.calendar))
                    .font(.subheadline)
                if let date = task.occurrenceDate {
                    LabeledContent(
                        "This one",
                        value: AppFormatters.shared.relativeDayAndTime(date, now: model.now)
                    )
                }
                if let last = routine.lastCompletedAt {
                    LabeledContent(
                        "Last done",
                        value: AppFormatters.shared.relativeDayAndTime(last, now: model.now)
                    )
                }
                Text("Completing or skipping this one doesn't change the routine.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if task.isRoutineOccurrence {
            // The routine row is gone but the occurrence remains. Saying so is
            // better than showing nothing and leaving a task nobody can explain.
            Section("Routine") {
                Text("This came from a routine that no longer exists. It's an ordinary task now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What this waits for, and what waits for it.
    @ViewBuilder
    private func dependencySection(for task: TaskItem) -> some View {
        let prerequisites = task.dependsOn.compactMap { model.task(id: $0) }
        let dependents = model.tasks.filter { $0.dependsOn.contains(task.id) }

        if !prerequisites.isEmpty || !dependents.isEmpty {
            Section("Order") {
                ForEach(prerequisites) { prerequisite in
                    LabeledContent {
                        TaskStatusBadge(status: prerequisite.status)
                    } label: {
                        Label(prerequisite.title, systemImage: "arrow.turn.up.left")
                            .foregroundStyle(prerequisite.status.isSettled ? .secondary : .primary)
                    }
                }
                if !prerequisites.isEmpty {
                    Text(
                        prerequisites.contains { !$0.status.isSettled }
                            // The reassurance that matters: silence here is
                            // deliberate, not the app forgetting.
                            ? "This is waiting. I won't chase you about it until it can be done."
                            : "Everything this was waiting for is settled."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                ForEach(dependents) { dependent in
                    Label("\(dependent.title) waits for this", systemImage: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The steps, in order, with the next one to actually do.
    @ViewBuilder
    private func preparationSection(for task: TaskItem) -> some View {
        let steps = task.preparationSteps.ordered

        if !steps.isEmpty {
            Section {
                ForEach(steps) { step in
                    Button {
                        Task { await model.completePreparationStep(step.id, taskID: task.id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                            Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(step.isCompleted ? Color.green : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .foregroundStyle(step.isCompleted ? .secondary : .primary)
                                    .strikethrough(step.isCompleted, color: .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)

                                Text(stepCaption(step))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(step.isCompleted)
                }
            } header: {
                Text("Steps")
            } footer: {
                // Section 45, said out loud. Ticking off every step is not the
                // same as the thing being done, and a footer is cheaper than a
                // user discovering it the hard way.
                Text("Ticking off steps doesn't complete the task itself.")
            }
        }
    }

    private func stepCaption(_ step: PreparationStep) -> String {
        let minutes = Int((step.estimatedDuration / 60).rounded())
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) min") }
        if step.necessity != .required { parts.append(step.necessity.rawValue) }
        if let start = step.scheduledStart {
            parts.append("from \(AppFormatters.shared.time(start))")
        }
        return parts.isEmpty ? "Step" : parts.joined(separator: " · ")
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
