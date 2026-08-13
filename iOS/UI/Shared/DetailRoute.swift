import AssistantDomain
import SwiftUI

/// The detail presentations that can be opened from more than one screen.
///
/// Sharing one route type means a task opened from the conversation, from
/// Today and from the task list all lands in the same view, with the same
/// actions.
enum DetailRoute: Identifiable, Hashable {
    case task(TaskItem.ID)
    case event(CalendarItem.ID)
    case reminderPlan(ReminderPlan.ID)

    var id: String {
        switch self {
        case .task(let id): return "task-\(id)"
        case .event(let id): return "event-\(id)"
        case .reminderPlan(let id): return "plan-\(id)"
        }
    }
}

private struct DetailSheetModifier: ViewModifier {
    @Binding var route: DetailRoute?

    func body(content: Content) -> some View {
        content.sheet(item: $route) { route in
            NavigationStack {
                switch route {
                case .task(let id):
                    TaskDetailView(taskID: id)
                case .event(let id):
                    EventDetailView(eventID: id)
                case .reminderPlan(let id):
                    ReminderPlanDetailView(planID: id)
                }
            }
            .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    /// Presents task, event and reminder-plan detail from a single binding.
    func detailSheet(route: Binding<DetailRoute?>) -> some View {
        modifier(DetailSheetModifier(route: route))
    }
}
