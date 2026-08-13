import AssistantDomain
import SwiftUI

/// Everything the assistant is keeping track of.
///
/// Grouped into To Do / In Progress / Done. The domain's finer states —
/// snoozed, missed, needs follow-up — stay visible on the row rather than
/// becoming their own sections, which would turn the screen into a status
/// report instead of a list of work.
struct TasksScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel = TasksViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Filter", selection: $viewModel.filter) {
                        ForEach(TaskListFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Theme.Spacing.sm, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if viewModel.isEmpty(for: model) {
                    Section {
                        EmptyStateView(
                            systemImage: "checklist",
                            title: "No tasks",
                            message: viewModel.emptyMessage
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } else {
                    ForEach(viewModel.sections(for: model)) { section in
                        Section(section.bucket.title) {
                            ForEach(section.tasks) { task in
                                TaskRowView(task: task) {
                                    viewModel.route = .task(task.id)
                                } onToggle: {
                                    Task { await toggle(task) }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await model.deleteTask(task.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if !task.isCompleted {
                                        Button {
                                            Task { await model.snoozeTask(task.id) }
                                        } label: {
                                            Label("Snooze", systemImage: "moon.zzz")
                                        }
                                        .tint(.purple)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton() }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.isShowingNewTask = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add task")
                }
            }
            .detailSheet(route: $viewModel.route)
            .sheet(isPresented: $viewModel.isShowingNewTask) {
                NavigationStack {
                    TaskEditorView(task: nil)
                }
                .presentationDragIndicator(.visible)
            }
            .animation(Theme.transition, value: model.tasks)
        }
    }

    /// The checkbox is a confirmation, which is the only thing that completes a
    /// task. Tapping a completed task reopens it.
    private func toggle(_ task: TaskPresentation) async {
        if task.isCompleted {
            await model.reopenTask(task.id)
        } else {
            await model.completeTask(task.id)
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    TasksScreen()
        .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
