import AssistantDomain
import Foundation
import SwiftUI

/// The filters offered on the Tasks screen.
enum TaskListFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case upcoming
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .completed: return "Completed"
        }
    }
}

/// The three buckets tasks are grouped into.
///
/// The domain keeps eight statuses; showing all eight at once would be noise.
/// Grouping is a display decision, and the finer state is still visible on the
/// row and in the detail view.
enum TaskBucket: String, CaseIterable, Identifiable {
    case toDo
    case inProgress
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toDo: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }

    static func containing(_ status: TaskStatus) -> TaskBucket {
        switch status {
        case .inProgress: return .inProgress
        case .completed: return .done
        default: return .toDo
        }
    }
}

/// A task shaped for a row.
struct TaskPresentation: Identifiable, Equatable {
    let id: TaskItem.ID
    let title: String
    let status: TaskStatus
    let statusLabel: String
    let importance: Importance
    /// "Due today · 9:00 PM", "Any time this week", "No time set"
    let timingLabel: String
    /// "Next reminder 6:00 PM"
    let reminderLabel: String?
    let isOverdue: Bool
    let isCompleted: Bool
    /// True when a reminder was dismissed without confirmation.
    let needsAttention: Bool
}

/// A bucket plus the tasks in it. A struct rather than a tuple because
/// `ForEach` needs a key path for identity.
struct TaskSection: Identifiable {
    let bucket: TaskBucket
    let tasks: [TaskPresentation]

    var id: String { bucket.id }
}

struct TaskPresenter {
    let now: Date
    let calendar: Calendar
    var formatters: AppFormatters = .shared

    func present(_ task: TaskItem, reminderPlans: [ReminderPlan]) -> TaskPresentation {
        let anchor = task.timing.anchorDate ?? task.deadline

        return TaskPresentation(
            id: task.id,
            title: task.title,
            status: task.status,
            statusLabel: Self.label(for: task.status),
            importance: task.importance,
            timingLabel: timingLabel(for: task),
            reminderLabel: reminderLabel(for: task, plans: reminderPlans),
            isOverdue: anchor.map { $0 < now && task.status.isOutstanding } ?? false,
            isCompleted: task.status == .completed,
            needsAttention: task.status == .needsFollowUp || task.status == .missed
        )
    }

    func timingLabel(for task: TaskItem) -> String {
        switch task.timing {
        case .fixed(let date):
            return formatters.relativeDayAndTime(date, now: now)
        case .dueBy(let date):
            return "Due \(formatters.relativeDayAndTime(date, now: now).lowercased())"
        case .flexible(let window):
            return "Any time before \(formatters.relativeDay(window.end, now: now).lowercased())"
        case .unscheduled:
            return "No time set"
        }
    }

    /// The next stage the assistant will deliver for this task, if any.
    func reminderLabel(for task: TaskItem, plans: [ReminderPlan]) -> String? {
        guard task.status.isOutstanding else { return nil }
        guard
            let planID = task.reminderPlanID,
            let plan = plans.first(where: { $0.id == planID })
        else { return nil }

        let presentation = ReminderPlanPresentation.make(
            from: plan,
            now: now,
            calendar: calendar,
            formatters: formatters
        )
        guard let next = presentation.stages.first(where: { !$0.hasPassed }) else { return nil }
        return "Next reminder \(next.whenLabel.lowercased())"
    }

    func filter(_ tasks: [TaskItem], by filter: TaskListFilter) -> [TaskItem] {
        switch filter {
        case .all:
            return tasks.filter { $0.status != .cancelled }
        case .today:
            return tasks.filter { task in
                guard task.status.isOutstanding else { return false }
                guard let date = task.timing.anchorDate ?? task.deadline else { return false }
                return calendar.isDate(date, inSameDayAs: now)
            }
        case .upcoming:
            return tasks.filter { task in
                guard task.status.isOutstanding else { return false }
                guard let date = task.timing.anchorDate ?? task.deadline else { return true }
                return date > now
            }
        case .completed:
            return tasks.filter { $0.status == .completed }
        }
    }

    func grouped(_ tasks: [TaskItem]) -> [(bucket: TaskBucket, tasks: [TaskItem])] {
        TaskBucket.allCases.compactMap { bucket in
            let matching = tasks
                .filter { TaskBucket.containing($0.status) == bucket }
                .sorted(by: Self.ordering)
            return matching.isEmpty ? nil : (bucket, matching)
        }
    }

    private static func ordering(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        let left = lhs.timing.anchorDate ?? lhs.deadline ?? .distantFuture
        let right = rhs.timing.anchorDate ?? rhs.deadline ?? .distantFuture
        if left == right { return lhs.importance > rhs.importance }
        return left < right
    }

    static func label(for status: TaskStatus) -> String {
        switch status {
        case .notStarted: return "To do"
        case .reminded: return "Reminded"
        case .snoozed: return "Snoozed"
        case .inProgress: return "In progress"
        case .completed: return "Done"
        case .missed: return "Missed"
        case .needsFollowUp: return "Needs follow-up"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .expired: return "Window closed"
        }
    }

    /// A one-line explanation of what a status means, shown in the detail view.
    static func explanation(for status: TaskStatus) -> String? {
        switch status {
        case .reminded:
            return "You've been reminded, but this isn't confirmed done yet."
        case .snoozed:
            return "Put off for now. I'll bring it back."
        case .needsFollowUp:
            return "A reminder was dismissed without confirming, so this is still open."
        case .missed:
            return "Its moment passed without confirmation."
        case .skipped:
            // Said explicitly because it is the one settled status that is
            // neither a success nor a failure, and because the reassurance
            // matters: skipping today is not calling off the routine.
            return "You skipped this one. Nothing else changed."
        case .expired:
            return "This was only worth doing at the time, and that time has gone."
        default:
            return nil
        }
    }
}

enum TaskStatusStyle {
    static func tint(for status: TaskStatus) -> Color {
        switch status {
        case .completed: return .green
        case .inProgress: return .accentColor
        case .missed, .needsFollowUp: return .orange
        case .snoozed: return .purple
        // Neither green nor orange. Skipping and expiring settle a task without
        // it having been done, and colouring them like success or like failure
        // would both be a lie.
        case .cancelled, .skipped, .expired: return .secondary
        case .notStarted, .reminded: return .secondary
        }
    }

    static func symbol(for status: TaskStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.lefthalf.filled"
        case .missed, .needsFollowUp: return "exclamationmark.circle"
        case .snoozed: return "moon.zzz"
        case .cancelled: return "xmark.circle"
        case .skipped: return "forward.end.circle"
        case .expired: return "clock.badge.xmark"
        case .notStarted, .reminded: return "circle"
        }
    }
}

enum ImportanceStyle {
    static func label(for importance: Importance) -> String {
        switch importance {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    /// Only high and critical get a marker; marking everything marks nothing.
    static func tint(for importance: Importance) -> Color? {
        switch importance {
        case .low, .normal: return nil
        case .high: return .orange
        case .critical: return .red
        }
    }
}
