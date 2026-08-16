#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData

/// `ReminderPlanRepository`, backed by SwiftData.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataReminderPlanRepository: ReminderPlanRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    /// Writes the plan and all its stages together.
    public func save(_ plan: ReminderPlan) async throws {
        let id = plan.id.rawValue
        try await persistence.mutate(entity: ReminderPlanMapper.entity) { context in
            let row: SDReminderPlan
            if let existing = try context.first(
                Self.descriptor(id: id), entity: ReminderPlanMapper.entity
            ) {
                ReminderPlanMapper.updateScalars(existing, from: plan)
                row = existing
            } else {
                let inserted = ReminderPlanMapper.makeRow(from: plan)
                context.insert(inserted)
                row = inserted
            }
            ReminderPlanMapper.reconcileStages(row, from: plan, in: context)
        }
    }

    public func plan(id: ReminderPlan.ID) async throws -> ReminderPlan? {
        let raw = id.rawValue
        return try await persistence.read { context in
            guard
                let row = try context.first(Self.descriptor(id: raw), entity: ReminderPlanMapper.entity)
            else { return nil }
            return try ReminderPlanMapper.makeDomain(from: row)
        }
    }

    public func plans(for reference: ReminderSubject.Reference) async throws -> [ReminderPlan] {
        try await persistence.read { context in
            // The reference is a three-way union stored across three nullable
            // columns. Fetching by the one that is populated keeps the query in
            // the store. The comparands are declared optional so each predicate
            // compares like with like.
            let descriptor: FetchDescriptor<SDReminderPlan>
            switch reference {
            case .task(let id):
                let raw: UUID? = id.rawValue
                descriptor = FetchDescriptor<SDReminderPlan>(
                    predicate: #Predicate { $0.subjectTaskID == raw },
                    sortBy: [SortDescriptor(\SDReminderPlan.createdAt, order: .forward)]
                )
            case .calendarItem(let id):
                let raw: UUID? = id.rawValue
                descriptor = FetchDescriptor<SDReminderPlan>(
                    predicate: #Predicate { $0.subjectCalendarItemID == raw },
                    sortBy: [SortDescriptor(\SDReminderPlan.createdAt, order: .forward)]
                )
            case .freeform(let text):
                let raw: String? = text
                descriptor = FetchDescriptor<SDReminderPlan>(
                    predicate: #Predicate { $0.subjectFreeform == raw },
                    sortBy: [SortDescriptor(\SDReminderPlan.createdAt, order: .forward)]
                )
            }

            // Oldest first, matching the existing repository, with the
            // identifier tiebreak applied here — `UUID` cannot be a sort
            // descriptor.
            return try context.fetchAll(descriptor, entity: ReminderPlanMapper.entity)
                .map(ReminderPlanMapper.makeDomain)
                .sorted { lhs, rhs in
                    lhs.createdAt == rhs.createdAt
                        ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                        : lhs.createdAt < rhs.createdAt
                }
        }
    }

    private static func descriptor(id: UUID) -> FetchDescriptor<SDReminderPlan> {
        FetchDescriptor<SDReminderPlan>(predicate: #Predicate { $0.id == id })
    }
}

#endif
