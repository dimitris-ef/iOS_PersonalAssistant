#if canImport(SwiftData)

import AssistantDomain
import Foundation
import SwiftData

/// `TaskItem` ↔ `SDTask`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum TaskMapper {
    static let entity = "task"

    // MARK: Domain → storage

    static func makeRow(from task: TaskItem) -> SDTask {
        let timing = encodeTiming(task.timing)
        let recurrence = encodeRecurrence(task.recurrence)

        return SDTask(
            id: task.id.rawValue,
            title: task.title,
            details: task.details,
            statusRaw: task.status.rawValue,
            importanceRaw: task.importance.rawValue,
            timingKind: timing.kind,
            timingDate: timing.date,
            timingWindowStart: timing.windowStart,
            timingWindowEnd: timing.windowEnd,
            deadline: task.deadline,
            preparationDuration: task.preparationDuration,
            travelDuration: task.travelDuration,
            recurrenceKind: recurrence.kind,
            recurrenceInterval: recurrence.interval,
            recurrenceWeekdays: recurrence.weekdays,
            recurrenceDay: recurrence.day,
            linkedCalendarItemID: task.linkedCalendarItemID?.rawValue,
            reminderPlanID: task.reminderPlanID?.rawValue,
            followUpCount: task.followUpCount,
            snoozeCount: task.snoozeCount,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            completedAt: task.completedAt
        )
    }

    /// Copies a task onto the row that already represents it.
    ///
    /// The id is not touched: this is the same task, and rewriting its
    /// identifier is how a "save" turns into a duplicate.
    static func update(_ row: SDTask, from task: TaskItem) {
        let timing = encodeTiming(task.timing)
        let recurrence = encodeRecurrence(task.recurrence)

        row.title = task.title
        row.details = task.details
        row.statusRaw = task.status.rawValue
        row.importanceRaw = task.importance.rawValue
        row.timingKind = timing.kind
        row.timingDate = timing.date
        row.timingWindowStart = timing.windowStart
        row.timingWindowEnd = timing.windowEnd
        row.deadline = task.deadline
        row.preparationDuration = task.preparationDuration
        row.travelDuration = task.travelDuration
        row.recurrenceKind = recurrence.kind
        row.recurrenceInterval = recurrence.interval
        row.recurrenceWeekdays = recurrence.weekdays
        row.recurrenceDay = recurrence.day
        row.linkedCalendarItemID = task.linkedCalendarItemID?.rawValue
        row.reminderPlanID = task.reminderPlanID?.rawValue
        row.followUpCount = task.followUpCount
        row.snoozeCount = task.snoozeCount
        row.createdAt = task.createdAt
        row.updatedAt = task.updatedAt
        row.completedAt = task.completedAt
    }

    // MARK: Storage → domain

    static func makeDomain(from row: SDTask) throws -> TaskItem {
        TaskItem(
            id: TaskItem.ID(row.id),
            title: row.title,
            details: row.details,
            status: try decodeEnum(TaskStatus.self, from: row.statusRaw, entity: entity, field: "status"),
            importance: try decodeEnum(
                Importance.self, from: row.importanceRaw, entity: entity, field: "importance"
            ),
            timing: try decodeTiming(row),
            deadline: row.deadline,
            preparationDuration: row.preparationDuration,
            travelDuration: row.travelDuration,
            recurrence: try decodeRecurrence(row),
            linkedCalendarItemID: row.linkedCalendarItemID.map { CalendarItem.ID($0) },
            reminderPlanID: row.reminderPlanID.map { ReminderPlan.ID($0) },
            followUpCount: row.followUpCount,
            snoozeCount: row.snoozeCount,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            completedAt: row.completedAt
        )
    }

    // MARK: Timing

    private static func encodeTiming(
        _ timing: TimingPreference
    ) -> (kind: String, date: Date?, windowStart: Date?, windowEnd: Date?) {
        switch timing {
        case .fixed(let date):
            return (TimingKindColumn.fixed, date, nil, nil)
        case .dueBy(let date):
            return (TimingKindColumn.dueBy, date, nil, nil)
        case .flexible(let window):
            return (TimingKindColumn.flexible, nil, window.start, window.end)
        case .unscheduled:
            return (TimingKindColumn.unscheduled, nil, nil, nil)
        }
    }

    private static func decodeTiming(_ row: SDTask) throws -> TimingPreference {
        switch row.timingKind {
        case TimingKindColumn.fixed:
            guard let date = row.timingDate else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "fixed timing has no date")
            }
            return .fixed(date)
        case TimingKindColumn.dueBy:
            guard let date = row.timingDate else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "dueBy timing has no date")
            }
            return .dueBy(date)
        case TimingKindColumn.flexible:
            guard let start = row.timingWindowStart, let end = row.timingWindowEnd else {
                throw PersistenceError.mappingFailed(
                    entity: entity, detail: "flexible timing has no window"
                )
            }
            return .flexible(TimeWindow(start: start, end: end))
        case TimingKindColumn.unscheduled:
            return .unscheduled
        default:
            throw PersistenceError.mappingFailed(
                entity: entity, detail: "unrecognised timing kind"
            )
        }
    }

    // MARK: Recurrence

    private static func encodeRecurrence(
        _ rule: RecurrenceRule?
    ) -> (kind: String?, interval: Int?, weekdays: [Int]?, day: Int?) {
        switch rule {
        case .none:
            return (nil, nil, nil, nil)
        case .daily(let interval):
            return (RecurrenceKindColumn.daily, interval, nil, nil)
        case .weekly(let interval, let weekdays):
            return (RecurrenceKindColumn.weekly, interval, weekdays, nil)
        case .monthly(let interval, let day):
            return (RecurrenceKindColumn.monthly, interval, nil, day)
        case .yearly(let interval):
            return (RecurrenceKindColumn.yearly, interval, nil, nil)
        }
    }

    private static func decodeRecurrence(_ row: SDTask) throws -> RecurrenceRule? {
        guard let kind = row.recurrenceKind else { return nil }
        let interval = row.recurrenceInterval ?? 1

        switch kind {
        case RecurrenceKindColumn.daily:
            return .daily(interval: interval)
        case RecurrenceKindColumn.weekly:
            return .weekly(interval: interval, weekdays: row.recurrenceWeekdays ?? [])
        case RecurrenceKindColumn.monthly:
            return .monthly(interval: interval, day: row.recurrenceDay ?? 1)
        case RecurrenceKindColumn.yearly:
            return .yearly(interval: interval)
        default:
            throw PersistenceError.mappingFailed(
                entity: entity, detail: "unrecognised recurrence kind"
            )
        }
    }
}

#endif
