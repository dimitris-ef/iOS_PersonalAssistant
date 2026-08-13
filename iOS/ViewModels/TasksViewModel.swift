import AssistantDomain
import Foundation
import Observation

/// Screen state for Tasks: the filter, and which task is open.
@MainActor
@Observable
final class TasksViewModel {
    var filter: TaskListFilter = .all
    var route: DetailRoute?
    var isShowingNewTask = false

    private func makePresenter(for model: AppModel) -> TaskPresenter {
        TaskPresenter(now: model.now, calendar: model.calendar)
    }

    func sections(for model: AppModel) -> [TaskSection] {
        let presenter = makePresenter(for: model)
        let filtered = presenter.filter(model.tasks, by: filter)

        return presenter.grouped(filtered).map { group in
            TaskSection(
                bucket: group.bucket,
                tasks: group.tasks.map {
                    presenter.present($0, reminderPlans: model.reminderPlans)
                }
            )
        }
    }

    func isEmpty(for model: AppModel) -> Bool {
        sections(for: model).allSatisfy { $0.tasks.isEmpty }
    }

    var emptyMessage: String {
        switch filter {
        case .all:
            return "Nothing waiting for you right now. Tell me what needs doing and I'll keep track of it."
        case .today:
            return "Nothing is due today. That's allowed."
        case .upcoming:
            return "Nothing scheduled ahead. Ask me to add something and I'll plan the reminders."
        case .completed:
            return "Nothing finished yet today."
        }
    }
}
