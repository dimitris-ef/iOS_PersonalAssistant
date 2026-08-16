#if canImport(SwiftData)

import Foundation
import SwiftData

/// How the store gets from one schema version to the next.
///
/// There is only one version today, so `stages` is empty and no migration runs.
/// The plan exists anyway, and is wired into the container from the first
/// launch, because the alternative is discovering at V2 that the store was
/// created without one — at which point the only cheap answer is deleting the
/// user's database, and that is not an answer.
///
/// ## Adding V2
///
/// 1. Copy the models into a new `PersonalAssistantSchemaV2` enum and change
///    them there. Never edit `PersonalAssistantSchemaV1` — it is a description
///    of what is already on disk, and rewriting history makes the migration a
///    lie.
/// 2. Add `PersonalAssistantSchemaV2.self` to `schemas`, after V1.
/// 3. Add a stage to `stages`:
///    - `.lightweight` when SwiftData can infer the change: adding an optional
///      property, adding a model, deleting a property, renaming via
///      `@Attribute(originalName:)`.
///    - `.custom` when it cannot: splitting a field, changing a type, making an
///      optional non-optional, or any change needing a value computed from the
///      old data. The `willMigrate`/`didMigrate` closures get a context for the
///      old and new stores respectively.
/// 4. Add a test that opens a store written by V1, migrates it, and asserts the
///    data survived. A migration without that test is a guess.
///
/// The rule that outranks all of the above: **a migration never deletes data.**
/// If a field cannot be derived, it becomes optional or takes a documented
/// default. It does not become a reason to start the store over.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [PersonalAssistantSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

#endif
