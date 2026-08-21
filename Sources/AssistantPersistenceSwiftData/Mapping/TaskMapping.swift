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
            // Recurrence columns are left nil: since V6 a recurring
            // responsibility is an `SDRoutine`, and writing a rule here too
            // would be a second definition of the same thing.
            recurrenceKind: nil,
            recurrenceInterval: nil,
            recurrenceWeekdays: nil,
            recurrenceDay: nil,
            linkedCalendarItemID: task.linkedCalendarItemID?.rawValue,
            reminderPlanID: task.reminderPlanID?.rawValue,
            followUpCount: task.followUpCount,
            snoozeCount: task.snoozeCount,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            completedAt: task.completedAt,
            estimatedDuration: task.estimatedDuration,
            routineID: task.routineID?.rawValue,
            occurrenceDate: task.occurrenceDate,
            dependsOn: task.dependsOn.isEmpty ? nil : task.dependsOn.map(\.rawValue),
            preparationStepsJSON: encodeSteps(task.preparationSteps),
            dismissalCount: task.dismissalCount,
            missCount: task.missCount
        )
    }

    /// Copies a task onto the row that already represents it.
    ///
    /// The id is not touched: this is the same task, and rewriting its
    /// identifier is how a "save" turns into a duplicate.
    static func update(_ row: SDTask, from task: TaskItem) {
        let timing = encodeTiming(task.timing)

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
        row.linkedCalendarItemID = task.linkedCalendarItemID?.rawValue
        row.reminderPlanID = task.reminderPlanID?.rawValue
        row.followUpCount = task.followUpCount
        row.snoozeCount = task.snoozeCount
        row.createdAt = task.createdAt
        row.updatedAt = task.updatedAt
        row.completedAt = task.completedAt
        row.estimatedDuration = task.estimatedDuration
        row.routineID = task.routineID?.rawValue
        row.occurrenceDate = task.occurrenceDate
        row.dependsOn = task.dependsOn.isEmpty ? nil : task.dependsOn.map(\.rawValue)
        row.preparationStepsJSON = encodeSteps(task.preparationSteps)
        row.dismissalCount = task.dismissalCount
        row.missCount = task.missCount
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
            estimatedDuration: row.estimatedDuration,
            routineID: row.routineID.map { Routine.ID($0) },
            occurrenceDate: row.occurrenceDate,
            dependsOn: (row.dependsOn ?? []).map { TaskItem.ID($0) },
            preparationSteps: decodeSteps(row.preparationStepsJSON),
            linkedCalendarItemID: row.linkedCalendarItemID.map { CalendarItem.ID($0) },
            reminderPlanID: row.reminderPlanID.map { ReminderPlan.ID($0) },
            followUpCount: row.followUpCount,
            snoozeCount: row.snoozeCount,
            dismissalCount: row.dismissalCount,
            missCount: row.missCount,
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

    // MARK: Preparation steps

    /// Steps as JSON, or nil when there are none.
    ///
    /// Nil rather than an empty array so a task that never had steps and one
    /// whose steps were all removed read back identically — there is no
    /// meaningful difference, and two representations of "none" is one more
    /// than any caller wants to handle.
    static func encodeSteps(_ steps: [PreparationStep]) -> Data? {
        guard !steps.isEmpty else { return nil }
        return try? JSONCoding.encoder.encode(steps.ordered)
    }

    /// Steps back from JSON.
    ///
    /// Unreadable payloads decode to no steps rather than throwing. A task is
    /// still a task without its preparation breakdown, and refusing to load
    /// someone's whole task list because one blob was written by a newer
    /// version would be a worse failure than losing the breakdown.
    static func decodeSteps(_ data: Data?) -> [PreparationStep] {
        guard let data else { return [] }
        return ((try? JSONCoding.decoder.decode([PreparationStep].self, from: data)) ?? []).ordered
    }
}

#endif
