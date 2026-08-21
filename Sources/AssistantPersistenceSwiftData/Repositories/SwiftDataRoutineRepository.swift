#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData

/// `RoutineRepository`, backed by SwiftData.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataRoutineRepository: RoutineRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func save(_ routine: Routine) async throws {
        let id = routine.id.rawValue
        try await persistence.mutate(entity: RoutineMapper.entity) { context in
            // Update-or-insert, keyed by the domain id — the same rule as every
            // other repository here. Editing a routine's time must change the
            // routine, not create a second one that also fires.
            if let existing = try context.first(Self.descriptor(id: id), entity: RoutineMapper.entity) {
                RoutineMapper.update(existing, from: routine)
            } else {
                context.insert(RoutineMapper.makeRow(from: routine))
            }
        }
    }

    public func routine(id: Routine.ID) async throws -> Routine? {
        let raw = id.rawValue
        return try await persistence.read { context in
            guard
                let row = try context.first(Self.descriptor(id: raw), entity: RoutineMapper.entity)
            else { return nil }
            return try RoutineMapper.makeDomain(from: row)
        }
    }

    public func routines(activeOnly: Bool) async throws -> [Routine] {
        try await persistence.read { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDRoutine>(),
                entity: RoutineMapper.entity
            )
            return try rows
                .map(RoutineMapper.makeDomain)
                .filter { !activeOnly || $0.isActive }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Removes the routine.
    ///
    /// Occurrences are deliberately left alone. They are ordinary tasks that
    /// point at this routine by id, and deleting yesterday's completed
    /// medication because the user stopped the prescription today would be
    /// rewriting history to tidy a foreign key. Their `routineID` becomes a
    /// dangling reference, which every reader already treats as "no routine".
    public func delete(id: Routine.ID) async throws {
        let raw = id.rawValue
        try await persistence.mutate(entity: RoutineMapper.entity) { context in
            guard
                let row = try context.first(Self.descriptor(id: raw), entity: RoutineMapper.entity)
            else { return }
            context.delete(row)
        }
    }

    private static func descriptor(id: UUID) -> FetchDescriptor<SDRoutine> {
        FetchDescriptor<SDRoutine>(predicate: #Predicate { $0.id == id })
    }
}

#endif
