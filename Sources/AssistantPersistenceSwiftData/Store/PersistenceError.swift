#if canImport(SwiftData)

import AssistantPersistence
import Foundation

/// What can go wrong in the persistence layer.
///
/// Typed and wrapped rather than letting SwiftData's own errors travel upwards:
/// the UI already knows how to show a `RepositoryError`, and nothing above the
/// repository boundary should have to know that the store is SwiftData at all.
///
/// Messages here describe the *operation*, never the data. A failure to save a
/// memory says which repository failed, not what the user asked to remember.
public enum PersistenceError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The `ModelContainer` could not be opened. Fatal for the session: there
    /// is nowhere to read from or write to.
    case initializationFailed(String)
    case saveFailed(entity: String, underlying: String)
    case fetchFailed(entity: String, underlying: String)
    /// A stored row could not be turned back into a domain value.
    case mappingFailed(entity: String, detail: String)
    case entityNotFound(entity: String)

    public var description: String {
        switch self {
        case .initializationFailed(let detail):
            return "Persistent storage could not be opened: \(detail)"
        case .saveFailed(let entity, let underlying):
            return "Saving \(entity) failed: \(underlying)"
        case .fetchFailed(let entity, let underlying):
            return "Loading \(entity) failed: \(underlying)"
        case .mappingFailed(let entity, let detail):
            return "A stored \(entity) could not be read: \(detail)"
        case .entityNotFound(let entity):
            return "No stored \(entity) was found."
        }
    }

    /// How this surfaces to code that only knows `RepositoryError`.
    public var asRepositoryError: RepositoryError {
        switch self {
        case .entityNotFound(let entity):
            return .notFound(entity)
        case .initializationFailed, .saveFailed, .fetchFailed, .mappingFailed:
            return .storageFailure(description)
        }
    }
}

#endif
