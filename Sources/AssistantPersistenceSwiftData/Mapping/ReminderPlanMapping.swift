#if canImport(SwiftData)

import AssistantDomain
import Foundation
import SwiftData

/// `ReminderPlan` ↔ `SDReminderPlan`, and `ReminderStage` ↔ `SDReminderStage`.
///
/// The plan keeps its shape in storage: multiple stages, each with its own
/// kind, offset, channel and escalation, plus the three policies that govern
/// follow-up, snoozing and completion. Flattening a plan to "one date" would
/// throw away the entire support strategy — which is the product.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum ReminderPlanMapper {
    static let entity = "reminder plan"

    // MARK: Domain → storage

    static func makeRow(from plan: ReminderPlan) -> SDReminderPlan {
        let reference = encodeReference(plan.subject.reference)
        let anchor = encodeAnchor(plan.subject.anchor)

        return SDReminderPlan(
            id: plan.id.rawValue,
            subjectReferenceKind: reference.kind,
            subjectTaskID: reference.taskID,
            subjectCalendarItemID: reference.calendarItemID,
            subjectFreeform: reference.freeform,
            subjectTitle: plan.subject.title,
            subjectImportanceRaw: plan.subject.importance.rawValue,
            subjectIsTimeFixed: plan.subject.isTimeFixed,
            subjectPreparationDuration: plan.subject.preparationDuration,
            subjectTravelDuration: plan.subject.travelDuration,
            anchorKind: anchor.kind,
            anchorDate: anchor.date,
            anchorWindowStart: anchor.windowStart,
            anchorWindowEnd: anchor.windowEnd,
            followUpIsEnabled: plan.followUp.isEnabled,
            followUpMaximum: plan.followUp.maximumFollowUps,
            followUpInterval: plan.followUp.interval,
            followUpEscalatesEachTime: plan.followUp.escalatesEachTime,
            snoozeIsAllowed: plan.snooze.isAllowed,
            snoozeDefaultDuration: plan.snooze.defaultDuration,
            snoozeMaximum: plan.snooze.maximumSnoozes,
            snoozeEscalateAfter: plan.snooze.escalateAfterSnoozes,
            completionRequiresExplicitConfirmation: plan.completion.requiresExplicitConfirmation,
            completionMarkMissedAfter: plan.completion.markMissedAfter,
            createdAt: plan.createdAt,
            generatedBy: plan.generatedBy,
            revision: plan.revision
        )
    }

    static func updateScalars(_ row: SDReminderPlan, from plan: ReminderPlan) {
        let reference = encodeReference(plan.subject.reference)
        let anchor = encodeAnchor(plan.subject.anchor)

        row.subjectReferenceKind = reference.kind
        row.subjectTaskID = reference.taskID
        row.subjectCalendarItemID = reference.calendarItemID
        row.subjectFreeform = reference.freeform
        row.subjectTitle = plan.subject.title
        row.subjectImportanceRaw = plan.subject.importance.rawValue
        row.subjectIsTimeFixed = plan.subject.isTimeFixed
        row.subjectPreparationDuration = plan.subject.preparationDuration
        row.subjectTravelDuration = plan.subject.travelDuration
        row.anchorKind = anchor.kind
        row.anchorDate = anchor.date
        row.anchorWindowStart = anchor.windowStart
        row.anchorWindowEnd = anchor.windowEnd
        row.followUpIsEnabled = plan.followUp.isEnabled
        row.followUpMaximum = plan.followUp.maximumFollowUps
        row.followUpInterval = plan.followUp.interval
        row.followUpEscalatesEachTime = plan.followUp.escalatesEachTime
        row.snoozeIsAllowed = plan.snooze.isAllowed
        row.snoozeDefaultDuration = plan.snooze.defaultDuration
        row.snoozeMaximum = plan.snooze.maximumSnoozes
        row.snoozeEscalateAfter = plan.snooze.escalateAfterSnoozes
        row.completionRequiresExplicitConfirmation = plan.completion.requiresExplicitConfirmation
        row.completionMarkMissedAfter = plan.completion.markMissedAfter
        row.createdAt = plan.createdAt
        row.generatedBy = plan.generatedBy
    }

    /// Diffs the stages by id, for the same reason messages are diffed: a stage
    /// that already exists keeps its row, so anything referring to
    /// `ReminderStage.ID` — a delivered notification, a scheduled reminder —
    /// still points at the same thing after a re-save.
    static func reconcileStages(
        _ row: SDReminderPlan,
        from plan: ReminderPlan,
        in context: ModelContext
    ) {
        var existing: [UUID: SDReminderStage] = [:]
        for stage in row.stages {
            existing[stage.id] = stage
        }

        var kept: Set<UUID> = []
        for (index, stage) in plan.stages.enumerated() {
            kept.insert(stage.id.rawValue)
            let offset = encodeOffset(stage.offset)

            if let found = existing[stage.id.rawValue] {
                found.kindRaw = stage.kind.rawValue
                found.channelRaw = stage.channel.rawValue
                found.escalationRaw = stage.escalation.rawValue
                found.message = stage.message
                found.requiresConfirmation = stage.requiresConfirmation
                found.sequence = index
                found.offsetKind = offset.kind
                found.offsetInterval = offset.interval
                found.offsetDays = offset.days
                found.offsetHour = offset.hour
                found.offsetMinute = offset.minute
                found.offsetDate = offset.date
                found.stateRaw = stage.state.rawValue
                found.deliveryStateRaw = stage.delivery.state.rawValue
                found.deliveryLastAttemptAt = stage.delivery.lastAttemptAt
                found.deliveryAttempts = stage.delivery.attempts
                found.deliveryFailureReason = stage.delivery.failureReason
                found.deliveryScheduledRevision = stage.delivery.scheduledRevision
                found.stateChangedAt = stage.stateChangedAt
                found.scheduledFor = stage.scheduledFor
            } else {
                let inserted = SDReminderStage(
                    id: stage.id.rawValue,
                    kindRaw: stage.kind.rawValue,
                    channelRaw: stage.channel.rawValue,
                    escalationRaw: stage.escalation.rawValue,
                    message: stage.message,
                    requiresConfirmation: stage.requiresConfirmation,
                    sequence: index,
                    offsetKind: offset.kind,
                    offsetInterval: offset.interval,
                    offsetDays: offset.days,
                    offsetHour: offset.hour,
                    offsetMinute: offset.minute,
                    offsetDate: offset.date,
                    stateRaw: stage.state.rawValue,
                    deliveryStateRaw: stage.delivery.state.rawValue,
                    deliveryLastAttemptAt: stage.delivery.lastAttemptAt,
                    deliveryAttempts: stage.delivery.attempts,
                    deliveryFailureReason: stage.delivery.failureReason,
                    deliveryScheduledRevision: stage.delivery.scheduledRevision,
                    stateChangedAt: stage.stateChangedAt,
                    scheduledFor: stage.scheduledFor
                )
                inserted.plan = row
                context.insert(inserted)
            }
        }

        for (id, stage) in existing where !kept.contains(id) {
            context.delete(stage)
        }
    }

    // MARK: Storage → domain

    static func makeDomain(from row: SDReminderPlan) throws -> ReminderPlan {
        let orderedStages = row.stages.sorted { $0.sequence < $1.sequence }

        return ReminderPlan(
            id: ReminderPlan.ID(row.id),
            subject: ReminderSubject(
                reference: try decodeReference(row),
                title: row.subjectTitle,
                anchor: try decodeAnchor(row),
                importance: try decodeEnum(
                    Importance.self,
                    from: row.subjectImportanceRaw,
                    entity: entity,
                    field: "subject importance"
                ),
                preparationDuration: row.subjectPreparationDuration,
                travelDuration: row.subjectTravelDuration,
                isTimeFixed: row.subjectIsTimeFixed
            ),
            stages: try orderedStages.map(makeStage),
            followUp: FollowUpPolicy(
                isEnabled: row.followUpIsEnabled,
                maximumFollowUps: row.followUpMaximum,
                interval: row.followUpInterval,
                escalatesEachTime: row.followUpEscalatesEachTime
            ),
            snooze: SnoozePolicy(
                isAllowed: row.snoozeIsAllowed,
                defaultDuration: row.snoozeDefaultDuration,
                maximumSnoozes: row.snoozeMaximum,
                escalateAfterSnoozes: row.snoozeEscalateAfter
            ),
            completion: CompletionPolicy(
                requiresExplicitConfirmation: row.completionRequiresExplicitConfirmation,
                markMissedAfter: row.completionMarkMissedAfter
            ),
            createdAt: row.createdAt,
            generatedBy: row.generatedBy,
            revision: row.revision
        )
    }

    private static func makeStage(from row: SDReminderStage) throws -> ReminderStage {
        ReminderStage(
            id: ReminderStage.ID(row.id),
            kind: try decodeEnum(
                ReminderStageKind.self, from: row.kindRaw, entity: "reminder stage", field: "kind"
            ),
            offset: try decodeOffset(row),
            channel: try decodeEnum(
                ReminderChannel.self, from: row.channelRaw, entity: "reminder stage", field: "channel"
            ),
            escalation: try decodeEnum(
                EscalationLevel.self,
                from: row.escalationRaw,
                entity: "reminder stage",
                field: "escalation"
            ),
            message: row.message,
            requiresConfirmation: row.requiresConfirmation,
            // A row written before schema V2 has no recorded state. It becomes
            // `.pending` — a reminder still waiting — because the alternative
            // would silently treat every reminder from before this feature as
            // already dealt with, which is the exact failure the feature fixes.
            state: row.stateRaw.map {
                ReminderStageState(rawValue: $0) ?? .pending
            } ?? .pending,
            stateChangedAt: row.stateChangedAt,
            scheduledFor: row.scheduledFor,
            // A row written before schema V9 has no recorded delivery state,
            // which reads back as `planned` — "the app has no record of having
            // scheduled this". That is the truth and also the safe direction:
            // the next reconciliation diffs the desired schedule against what
            // iOS actually holds, so a request the old build already made is
            // recognised and left alone rather than duplicated.
            delivery: StageDelivery(
                state: row.deliveryStateRaw
                    .flatMap(StageDeliveryState.init(rawValue:)) ?? .planned,
                lastAttemptAt: row.deliveryLastAttemptAt,
                attempts: row.deliveryAttempts,
                failureReason: row.deliveryFailureReason,
                scheduledRevision: row.deliveryScheduledRevision
            )
        )
    }

    // MARK: Subject reference

    private static func encodeReference(
        _ reference: ReminderSubject.Reference
    ) -> (kind: String, taskID: UUID?, calendarItemID: UUID?, freeform: String?) {
        switch reference {
        case .task(let id):
            return (ReferenceKindColumn.task, id.rawValue, nil, nil)
        case .calendarItem(let id):
            return (ReferenceKindColumn.calendarItem, nil, id.rawValue, nil)
        case .freeform(let text):
            return (ReferenceKindColumn.freeform, nil, nil, text)
        }
    }

    private static func decodeReference(_ row: SDReminderPlan) throws -> ReminderSubject.Reference {
        switch row.subjectReferenceKind {
        case ReferenceKindColumn.task:
            guard let id = row.subjectTaskID else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "task reference has no id")
            }
            return .task(TaskItem.ID(id))
        case ReferenceKindColumn.calendarItem:
            guard let id = row.subjectCalendarItemID else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "event reference has no id")
            }
            return .calendarItem(CalendarItem.ID(id))
        case ReferenceKindColumn.freeform:
            return .freeform(row.subjectFreeform ?? "")
        default:
            throw PersistenceError.mappingFailed(entity: entity, detail: "unrecognised subject reference")
        }
    }

    // MARK: Anchor

    private static func encodeAnchor(
        _ anchor: ReminderAnchor
    ) -> (kind: String, date: Date?, windowStart: Date?, windowEnd: Date?) {
        switch anchor {
        case .moment(let date):
            return (AnchorKindColumn.moment, date, nil, nil)
        case .deadline(let date):
            return (AnchorKindColumn.deadline, date, nil, nil)
        case .window(let window):
            return (AnchorKindColumn.window, nil, window.start, window.end)
        case .unscheduled:
            return (AnchorKindColumn.unscheduled, nil, nil, nil)
        }
    }

    private static func decodeAnchor(_ row: SDReminderPlan) throws -> ReminderAnchor {
        switch row.anchorKind {
        case AnchorKindColumn.moment:
            guard let date = row.anchorDate else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "moment anchor has no date")
            }
            return .moment(date)
        case AnchorKindColumn.deadline:
            guard let date = row.anchorDate else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "deadline anchor has no date")
            }
            return .deadline(date)
        case AnchorKindColumn.window:
            guard let start = row.anchorWindowStart, let end = row.anchorWindowEnd else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "window anchor has no window")
            }
            return .window(TimeWindow(start: start, end: end))
        case AnchorKindColumn.unscheduled:
            return .unscheduled
        default:
            throw PersistenceError.mappingFailed(entity: entity, detail: "unrecognised anchor kind")
        }
    }

    // MARK: Stage offset

    private static func encodeOffset(
        _ offset: ReminderOffset
    ) -> (kind: String, interval: Double?, days: Int?, hour: Int?, minute: Int?, date: Date?) {
        switch offset {
        case .beforeAnchor(let interval):
            return (OffsetKindColumn.beforeAnchor, interval, nil, nil, nil, nil)
        case .afterAnchor(let interval):
            return (OffsetKindColumn.afterAnchor, interval, nil, nil, nil, nil)
        case .daysBefore(let days, let time):
            return (OffsetKindColumn.daysBefore, nil, days, time.hour, time.minute, nil)
        case .morningOf(let time):
            return (OffsetKindColumn.morningOf, nil, nil, time.hour, time.minute, nil)
        case .absolute(let date):
            return (OffsetKindColumn.absolute, nil, nil, nil, nil, date)
        }
    }

    private static func decodeOffset(_ row: SDReminderStage) throws -> ReminderOffset {
        let entity = "reminder stage"

        switch row.offsetKind {
        case OffsetKindColumn.beforeAnchor:
            guard let interval = row.offsetInterval else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "offset has no interval")
            }
            return .beforeAnchor(interval)
        case OffsetKindColumn.afterAnchor:
            guard let interval = row.offsetInterval else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "offset has no interval")
            }
            return .afterAnchor(interval)
        case OffsetKindColumn.daysBefore:
            guard
                let days = row.offsetDays,
                let time = TimeOfDay.from(hour: row.offsetHour, minute: row.offsetMinute)
            else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "offset has no day and time")
            }
            return .daysBefore(days, at: time)
        case OffsetKindColumn.morningOf:
            guard let time = TimeOfDay.from(hour: row.offsetHour, minute: row.offsetMinute) else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "offset has no time of day")
            }
            return .morningOf(time)
        case OffsetKindColumn.absolute:
            guard let date = row.offsetDate else {
                throw PersistenceError.mappingFailed(entity: entity, detail: "offset has no date")
            }
            return .absolute(date)
        default:
            throw PersistenceError.mappingFailed(entity: entity, detail: "unrecognised offset kind")
        }
    }
}

#endif
