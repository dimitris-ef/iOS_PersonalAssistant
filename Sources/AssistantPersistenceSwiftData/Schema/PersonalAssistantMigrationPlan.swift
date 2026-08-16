#if canImport(SwiftData)

import Foundation
import SwiftData

/// How the store gets from one schema version to the next.
///
/// ## V1 → V2
///
/// Reminder stages gained three optional properties: their lifecycle state,
/// when that state last changed, and the concrete moment they are due. All
/// three are nullable, so the migration is inferred — a `.lightweight` stage.
///
/// **What existing rows become.** A stage written by V1 has none of the new
/// columns, so it reads back as `state == nil`, which the mapper resolves to
/// `.pending`. That default is chosen deliberately: an old stage becomes a
/// reminder still waiting to happen, never a finished one. The opposite default
/// would silently mark every reminder from before this feature as dealt with,
/// which is exactly the "support quietly stops" failure the feature exists to
/// fix. `scheduledFor` stays nil, so an unresolvable old stage is skipped by
/// reconciliation rather than being treated as overdue the moment the app
/// opens. Nothing is deleted and no task's status is touched.
///
/// ## Adding V3
///
/// 1. Copy the models into a new `PersonalAssistantSchemaV3` enum and change
///    them there. Never edit an older version — it describes what is already on
///    disk, and rewriting history makes the migration a lie. See the note in
///    `PersonalAssistantSchemaV2` about nesting the models per version, which
///    is a prerequisite for any change that is not purely additive.
/// 2. Add `PersonalAssistantSchemaV3.self` to `schemas`, after V2.
/// 3. Add a stage to `stages`:
///    - `.lightweight` when SwiftData can infer the change: adding an optional
///      property, adding a model, deleting a property, renaming via
///      `@Attribute(originalName:)`.
///    - `.custom` when it cannot: splitting a field, changing a type, making an
///      optional non-optional, or any change needing a value computed from the
///      old data. The `willMigrate`/`didMigrate` closures get a context for the
///      old and new stores respectively.
/// 4. Add a test that opens a store written by the previous version, migrates
///    it, and asserts the data survived. A migration without that test is a
///    guess.
///
/// The rule that outranks all of the above: **a migration never deletes data.**
/// If a field cannot be derived, it becomes optional or takes a documented
/// default. It does not become a reason to start the store over.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [PersonalAssistantSchemaV1.self, PersonalAssistantSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Purely additive, all-nullable. Nothing to compute, nothing to lose.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: PersonalAssistantSchemaV1.self,
        toVersion: PersonalAssistantSchemaV2.self
    )
}

#endif
