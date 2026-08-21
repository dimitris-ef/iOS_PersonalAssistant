#if canImport(SwiftData)

import AssistantDomain
import Foundation
import SwiftData

/// `Routine` ↔ `SDRoutine`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum RoutineMapper {
    static let entity = "routine"

    // MARK: Domain → storage

    static func makeRow(from routine: Routine) -> SDRoutine {
        SDRoutine(
            id: routine.id.rawValue,
            title: routine.title,
            details: routine.details,
            importanceRaw: routine.importance.rawValue,
            isActive: routine.isActive,
            frequencyRaw: routine.recurrence.frequency.rawValue,
            interval: routine.recurrence.interval,
            weekdays: routine.recurrence.weekdays,
            dayOfMonth: routine.recurrence.dayOfMonth,
            minuteOfDay: routine.recurrence.timeOfDay.minutesFromMidnight,
            recurrenceStart: routine.recurrence.startDate,
            recurrenceEnd: routine.recurrence.endDate,
            recoveryEnabled: routine.recovery.isEnabled,
            recoveryWindow: routine.recovery.window,
            recoveryAllowsNextDay: routine.recovery.allowsNextDay,
            preparationDuration: routine.preparationDuration,
            travelDuration: routine.travelDuration,
            preparationStepsJSON: TaskMapper.encodeSteps(routine.preparationSteps),
            lastCompletedAt: routine.lastCompletedAt,
            lastMissedAt: routine.lastMissedAt,
            createdAt: routine.createdAt,
            updatedAt: routine.updatedAt
        )
    }

    /// Copies a routine onto the row that already represents it.
    ///
    /// The id is not touched — this is the same responsibility, and rewriting
    /// its identifier would orphan every occurrence pointing at it.
    static func update(_ row: SDRoutine, from routine: Routine) {
        row.title = routine.title
        row.details = routine.details
        row.importanceRaw = routine.importance.rawValue
        row.isActive = routine.isActive
        row.frequencyRaw = routine.recurrence.frequency.rawValue
        row.interval = routine.recurrence.interval
        row.weekdays = routine.recurrence.weekdays
        row.dayOfMonth = routine.recurrence.dayOfMonth
        row.minuteOfDay = routine.recurrence.timeOfDay.minutesFromMidnight
        row.recurrenceStart = routine.recurrence.startDate
        row.recurrenceEnd = routine.recurrence.endDate
        row.recoveryEnabled = routine.recovery.isEnabled
        row.recoveryWindow = routine.recovery.window
        row.recoveryAllowsNextDay = routine.recovery.allowsNextDay
        row.preparationDuration = routine.preparationDuration
        row.travelDuration = routine.travelDuration
        row.preparationStepsJSON = TaskMapper.encodeSteps(routine.preparationSteps)
        row.lastCompletedAt = routine.lastCompletedAt
        row.lastMissedAt = routine.lastMissedAt
        row.createdAt = routine.createdAt
        row.updatedAt = routine.updatedAt
    }

    // MARK: Storage → domain

    static func makeDomain(from row: SDRoutine) throws -> Routine {
        Routine(
            id: Routine.ID(row.id),
            title: row.title,
            details: row.details,
            recurrence: RecurrenceRule(
                frequency: try decodeEnum(
                    RecurrenceRule.Frequency.self,
                    from: row.frequencyRaw,
                    entity: entity,
                    field: "frequency"
                ),
                interval: row.interval,
                weekdays: row.weekdays,
                dayOfMonth: row.dayOfMonth,
                timeOfDay: TimeOfDay(
                    hour: row.minuteOfDay / 60,
                    minute: row.minuteOfDay % 60
                ),
                startDate: row.recurrenceStart,
                endDate: row.recurrenceEnd
            ),
            importance: try decodeEnum(
                Importance.self,
                from: row.importanceRaw,
                entity: entity,
                field: "importance"
            ),
            isActive: row.isActive,
            recovery: RoutineRecoveryPolicy(
                isEnabled: row.recoveryEnabled,
                window: row.recoveryWindow,
                allowsNextDay: row.recoveryAllowsNextDay
            ),
            preparationDuration: row.preparationDuration,
            travelDuration: row.travelDuration,
            preparationSteps: TaskMapper.decodeSteps(row.preparationStepsJSON),
            lastCompletedAt: row.lastCompletedAt,
            lastMissedAt: row.lastMissedAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }
}

#endif
