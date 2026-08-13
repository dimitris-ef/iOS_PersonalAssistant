import AssistantDomain
import ExecutiveSupport
import Foundation
import SwiftUI

/// One entry on the Today timeline.
struct TodayTimelineItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case task
        case preparation
        case leave
        case event
        case reminder

        var label: String {
            switch self {
            case .task: return "Task"
            case .preparation: return "Preparation"
            case .leave: return "Leave reminder"
            case .event: return "Calendar event"
            case .reminder: return "Reminder"
            }
        }

        var symbol: String {
            switch self {
            case .task: return "circle"
            case .preparation: return "hourglass"
            case .leave: return "figure.walk"
            case .event: return "calendar"
            case .reminder: return "bell"
            }
        }

        var tint: Color {
            switch self {
            case .task: return .secondary
            case .preparation: return .orange
            case .leave: return .pink
            case .event: return .accentColor
            case .reminder: return .secondary
            }
        }
    }

    enum Reference: Equatable {
        case task(TaskItem.ID)
        case event(CalendarItem.ID)
    }

    let id: String
    let date: Date
    let title: String
    let kind: Kind
    let reference: Reference?
    let isDone: Bool
    let hasPassed: Bool
}

/// The single most relevant thing coming up, given more weight on screen.
struct UpNextItem: Equatable {
    let title: String
    let timeLabel: String
    let date: Date
    /// "Start getting ready in 1h 25m"
    let leadInLabel: String?
    let reference: TodayTimelineItem.Reference
    let isTask: Bool
}

/// Builds everything the Today screen shows.
///
/// Kept out of the view so the summary sentence and the timeline ordering are
/// plain, testable functions rather than logic buried in a `body`.
struct TodayPresenter {
    let now: Date
    let calendar: Calendar
    var formatters: AppFormatters = .shared

    // MARK: Timeline

    func timeline(
        tasks: [TaskItem],
        events: [CalendarItem],
        reminderPlans: [ReminderPlan]
    ) -> [TodayTimelineItem] {
        var items: [TodayTimelineItem] = []

        for event in events where calendar.isDate(event.start, inSameDayAs: now) {
            items.append(
                TodayTimelineItem(
                    id: "event-\(event.id)",
                    date: event.start,
                    title: event.title,
                    kind: .event,
                    reference: .event(event.id),
                    isDone: false,
                    hasPassed: event.start < now
                )
            )
        }

        for task in tasks {
            guard let date = task.timing.anchorDate ?? task.deadline else { continue }
            guard calendar.isDate(date, inSameDayAs: now) else { continue }
            guard task.status != .cancelled else { continue }

            items.append(
                TodayTimelineItem(
                    id: "task-\(task.id)",
                    date: date,
                    title: task.title,
                    kind: .task,
                    reference: .task(task.id),
                    isDone: task.status == .completed,
                    hasPassed: date < now
                )
            )
        }

        // Preparation and leave stages are the reason this screen is not just a
        // calendar: they are the assistant's own additions to the day.
        let resolver = ReminderScheduleResolver(calendar: calendar)
        for plan in reminderPlans {
            let scheduled = resolver.resolve(plan: plan, now: .distantPast)
            for reminder in scheduled {
                guard calendar.isDate(reminder.fireDate, inSameDayAs: now) else { continue }
                guard let kind = timelineKind(for: reminder.kind) else { continue }

                items.append(
                    TodayTimelineItem(
                        id: "stage-\(reminder.stageID)",
                        date: reminder.fireDate,
                        title: reminder.body,
                        kind: kind,
                        reference: reference(for: plan),
                        isDone: false,
                        hasPassed: reminder.fireDate < now
                    )
                )
            }
        }

        return items.sorted { $0.date < $1.date }
    }

    /// Only the stages that represent something the user has to *do* earn a row.
    /// Advance notices and same-day heads-ups would just clutter the day.
    private func timelineKind(for stage: ReminderStageKind) -> TodayTimelineItem.Kind? {
        switch stage {
        case .preparation: return .preparation
        case .leave: return .leave
        case .nudge, .followUp: return .reminder
        case .advanceNotice, .morningOf, .finalCall: return nil
        }
    }

    private func reference(for plan: ReminderPlan) -> TodayTimelineItem.Reference? {
        switch plan.subject.reference {
        case .task(let id): return .task(id)
        case .calendarItem(let id): return .event(id)
        case .freeform: return nil
        }
    }

    // MARK: Up next

    func upNext(
        tasks: [TaskItem],
        events: [CalendarItem],
        reminderPlans: [ReminderPlan]
    ) -> UpNextItem? {
        let upcomingEvent = events
            .filter { $0.start > now }
            .min { $0.start < $1.start }

        let upcomingTask = tasks
            .filter { task in
                guard task.status.isOutstanding else { return false }
                guard let date = task.timing.anchorDate ?? task.deadline else { return false }
                return date > now
            }
            .min { lhs, rhs in
                let left = lhs.timing.anchorDate ?? lhs.deadline ?? .distantFuture
                let right = rhs.timing.anchorDate ?? rhs.deadline ?? .distantFuture
                return left < right
            }

        let eventDate = upcomingEvent?.start ?? .distantFuture
        let taskDate = upcomingTask.flatMap { $0.timing.anchorDate ?? $0.deadline } ?? .distantFuture

        if let event = upcomingEvent, eventDate <= taskDate {
            return UpNextItem(
                title: event.title,
                timeLabel: formatters.relativeDayAndTime(event.start, now: now),
                date: event.start,
                leadInLabel: leadInLabel(for: event, plans: reminderPlans),
                reference: .event(event.id),
                isTask: false
            )
        }

        if let task = upcomingTask, let date = task.timing.anchorDate ?? task.deadline {
            return UpNextItem(
                title: task.title,
                timeLabel: formatters.relativeDayAndTime(date, now: now),
                date: date,
                leadInLabel: "Due \(formatters.relativeToNow(date, now: now))",
                reference: .task(task.id),
                isTask: true
            )
        }

        return nil
    }

    /// "Start getting ready in 1h 25m" — the sentence that actually helps.
    private func leadInLabel(for event: CalendarItem, plans: [ReminderPlan]) -> String? {
        guard
            let plan = plans.first(where: { $0.subject.reference == .calendarItem(event.id) })
        else { return nil }

        let resolver = ReminderScheduleResolver(calendar: calendar)
        let scheduled = resolver.resolve(plan: plan, now: .distantPast)

        if let preparation = scheduled.first(where: { $0.kind == .preparation }) {
            if preparation.fireDate > now {
                return "Start getting ready \(formatters.relativeToNow(preparation.fireDate, now: now))"
            }
            if let leave = scheduled.first(where: { $0.kind == .leave }), leave.fireDate > now {
                return "Leave \(formatters.relativeToNow(leave.fireDate, now: now))"
            }
            return "You should be getting ready now"
        }
        return "Starts \(formatters.relativeToNow(event.start, now: now))"
    }

    // MARK: Summary

    /// The assistant's read on the day.
    ///
    /// Generated from the data rather than canned, so it stays true as the
    /// demo state changes. A real model will write this later; the shape of
    /// what it produces is what matters now.
    func summary(
        tasks: [TaskItem],
        events: [CalendarItem],
        reminderPlans: [ReminderPlan]
    ) -> String {
        let todayEvents = events
            .filter { calendar.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start < $1.start }

        let openTasks = tasks.filter { task in
            guard task.status.isOutstanding else { return false }
            guard let date = task.timing.anchorDate ?? task.deadline else { return false }
            return calendar.isDate(date, inSameDayAs: now)
        }

        if todayEvents.isEmpty && openTasks.isEmpty {
            return "Nothing scheduled today. If something comes up, tell me and I'll plan around it."
        }

        var sentences: [String] = []

        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        let morningCount = todayEvents.filter { $0.start < noon }.count
            + openTasks.filter { ($0.timing.anchorDate ?? $0.deadline ?? now) < noon }.count
        sentences.append(
            morningCount <= 1
                ? "You have a fairly light morning."
                : "Your morning has \(morningCount) things in it."
        )

        if let main = todayEvents.max(by: { $0.importance < $1.importance }) {
            sentences.append(
                "Your main priority is \(main.title.lowercased()) at \(formatters.time(main.start))."
            )

            if let plan = reminderPlans.first(where: {
                $0.subject.reference == .calendarItem(main.id)
            }) {
                let resolver = ReminderScheduleResolver(calendar: calendar)
                let scheduled = resolver.resolve(plan: plan, now: .distantPast)
                if let preparation = scheduled.first(where: { $0.kind == .preparation }) {
                    sentences.append(
                        "You should start getting ready around \(formatters.time(preparation.fireDate))."
                    )
                }
            }
        } else if let task = openTasks.first {
            sentences.append("The main thing open is \(task.title.lowercased()).")
        }

        if openTasks.count > 1 {
            sentences.append("\(openTasks.count) tasks are still open today.")
        }

        return sentences.joined(separator: " ")
    }
}
