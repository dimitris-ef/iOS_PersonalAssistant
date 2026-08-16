#if canImport(SwiftData)

import Foundation
import SwiftData

/// Owns the one `ModelContext` the repositories write through.
///
/// `ModelContext` is not `Sendable` and must not be passed between concurrency
/// domains. Rather than each repository inventing its own answer to that, they
/// share this actor: it holds the context, and hands it to a closure that runs
/// on the actor's executor. The context never escapes — only mapped domain
/// values come back out, and those are `Sendable`.
///
/// Note what this deliberately is *not*: it has no `saveTask`, no
/// `fetchMemories`, no per-entity methods at all. Repository behaviour stays in
/// the repositories, split the way the protocols are split. This is a
/// coordinator for context access, not a manager that accumulates every
/// operation in the app.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@ModelActor
public actor AssistantPersistenceActor {
    /// Runs `work` against the shared context.
    ///
    /// Reads pass the fetched rows through a mapper and return domain values.
    /// Writes mutate rows and are followed by `save()` in ``mutate(_:)``, which
    /// is what callers should use when they change anything.
    public func read<T: Sendable>(_ work: @Sendable (ModelContext) throws -> T) throws -> T {
        try work(modelContext)
    }

    /// Runs `work` and commits.
    ///
    /// Saving here rather than leaving it to SwiftData's autosave is
    /// deliberate: a repository call is a user action that has already
    /// happened — a task completed, a memory written — and it should be on disk
    /// before the call returns rather than whenever the next runloop turn
    /// decides. One save per repository operation, not one per property.
    ///
    /// The save covers everything the closure touched, so a multi-entity write
    /// — a conversation and its messages, a plan and its stages — either lands
    /// whole or not at all. On failure the context is rolled back so a partial
    /// object graph cannot be left behind for the next operation to trip over.
    @discardableResult
    public func mutate<T: Sendable>(
        entity: String,
        _ work: @Sendable (ModelContext) throws -> T
    ) throws -> T {
        do {
            let result = try work(modelContext)
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            if let persistence = error as? PersistenceError { throw persistence }
            throw PersistenceError.saveFailed(entity: entity, underlying: String(describing: error))
        }
    }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension ModelContext {
    /// Fetch helper that turns SwiftData's errors into ours.
    func fetchAll<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        entity: String
    ) throws -> [T] {
        do {
            return try fetch(descriptor)
        } catch {
            throw PersistenceError.fetchFailed(entity: entity, underlying: String(describing: error))
        }
    }

    /// The single row with this domain id, if it exists.
    ///
    /// Every lookup in this layer goes through the domain identifier rather
    /// than SwiftData's object identity, which is what makes "load, edit, save"
    /// update a row instead of adding one.
    func first<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        entity: String
    ) throws -> T? {
        var limited = descriptor
        limited.fetchLimit = 1
        return try fetchAll(limited, entity: entity).first
    }
}

#endif
