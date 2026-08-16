#if canImport(SwiftData)

import Foundation
import SwiftData

/// Where the store lives.
public enum PersistenceLocation: Sendable {
    /// The app's normal on-disk store, in Application Support. This is what a
    /// real user runs on.
    case applicationDefault
    /// A specific file. Used by tests that need a store they can close and
    /// reopen, and by anything that wants an isolated database.
    case file(URL)
    /// No file at all.
    ///
    /// For tests and for the demo/preview configuration. **Never** for a normal
    /// launch: an in-memory store looks exactly like a working one right up to
    /// the moment the user closes the app and loses everything.
    case inMemory
}

/// Builds the one `ModelContainer` the application uses.
///
/// One container, one store, one schema — repositories share it rather than
/// each opening their own, because two containers over the same file are two
/// caches that disagree.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum AssistantPersistenceContainer {
    /// The current schema. Kept as one value so the container, the migration
    /// plan and the tests cannot drift apart.
    ///
    /// This is always the *newest* version. The migration plan is what knows
    /// how to get an older store here.
    public static var schema: Schema {
        Schema(PersonalAssistantSchemaV2.models, version: PersonalAssistantSchemaV2.versionIdentifier)
    }

    /// Opens the store.
    ///
    /// Throws rather than falling back. A silent fallback to in-memory storage
    /// would be the worst possible failure mode here: the app would look
    /// healthy, accept a day's worth of tasks and memories, and lose them at
    /// termination. The caller decides what to tell the user; it is not this
    /// function's business to paper over it.
    public static func make(location: PersistenceLocation = .applicationDefault) throws -> ModelContainer {
        let configuration: ModelConfiguration
        switch location {
        case .applicationDefault:
            configuration = ModelConfiguration(schema: schema)
        case .file(let url):
            configuration = ModelConfiguration(schema: schema, url: url)
        case .inMemory:
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: PersonalAssistantMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            throw PersistenceError.initializationFailed(String(describing: error))
        }
    }
}

#endif
