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
/// ## V2 → V3
///
/// Memories gained `confidenceValue`, one nullable column, so this is inferred
/// too.
///
/// **What existing rows become.** A memory written before V3 has no recorded
/// confidence, so the mapper derives one from the `source` it *did* record —
/// an explicitly stated memory stays trusted, an inferred one stays less so.
/// That is better evidence than a blanket default, and it keeps the
/// distinction the application had already made. A memory whose source is not
/// recognised falls back to `.legacy`, which is trusted enough not to drop out
/// of ranking: treating everything from before this feature as doubtful would
/// quietly discard what the assistant already knew about someone.
///
/// ## Adding V4
///
/// 1. Copy the models into a new `PersonalAssistantSchemaV4` enum and change
///    them there. Never edit an older version — it describes what is already on
///    disk, and rewriting history makes the migration a lie. See the note in
///    `PersonalAssistantSchemaV2` about nesting the models per version, which
///    is a prerequisite for any change that is not purely additive.
/// 2. Add `PersonalAssistantSchemaV4.self` to `schemas`, after V3.
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
        [
            PersonalAssistantSchemaV1.self,
            PersonalAssistantSchemaV2.self,
            PersonalAssistantSchemaV3.self,
            PersonalAssistantSchemaV4.self,
        ]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4]
    }

    /// Purely additive, all-nullable. Nothing to compute, nothing to lose.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: PersonalAssistantSchemaV1.self,
        toVersion: PersonalAssistantSchemaV2.self
    )

    /// One nullable column on memories. Confidence for existing rows is derived
    /// at read time from their recorded source, so there is nothing to compute
    /// here either.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: PersonalAssistantSchemaV2.self,
        toVersion: PersonalAssistantSchemaV3.self
    )

    /// Three columns on the settings row for voice. The two booleans carry
    /// declared defaults of `false` and the locale is optional, so every
    /// existing row already has a correct answer and there is nothing to
    /// compute.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: PersonalAssistantSchemaV3.self,
        toVersion: PersonalAssistantSchemaV4.self
    )
}

#endif
