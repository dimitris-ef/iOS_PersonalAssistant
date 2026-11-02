#if canImport(SwiftData)

import AssistantPersistenceSwiftData
import SwiftData
import XCTest

/// Guards the versioning setup itself.
///
/// None of this is about today's data. It is about V2: a store opened without a
/// migration plan, or with a schema whose version was never declared, has no
/// path forward except deleting it — and by then the data being deleted is
/// somebody's.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class SchemaVersioningTests: XCTestCase {

    func testTheSchemaIsVersioned() {
        XCTAssertEqual(PersonalAssistantSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
    }

    /// Every version is listed, and there is a stage between each consecutive
    /// pair.
    ///
    /// Stated as a relationship rather than as counts. This test previously
    /// asserted "one schema, no stages", which was true when it was written and
    /// silently wrong for two milestones afterwards — a gap that only appeared
    /// once anything compiled the suite. A missing stage means a store from the
    /// previous version cannot be opened at all.
    func testTheMigrationPlanCoversEveryVersion() {
        let schemas = PersonalAssistantMigrationPlan.schemas
        let stages = PersonalAssistantMigrationPlan.stages

        XCTAssertFalse(schemas.isEmpty)
        XCTAssertEqual(
            stages.count,
            schemas.count - 1,
            "each consecutive pair of schema versions needs exactly one migration stage"
        )

        // In ascending order, so the plan describes a path rather than a set.
        let versions = schemas.map { $0.versionIdentifier }
        XCTAssertEqual(versions, versions.sorted())
        // V9, not V1: the oldest store any shipped build ever wrote. See "Why
        // the plan starts at V9" on the plan.
        XCTAssertEqual(versions.first, PersonalAssistantSchemaV9.versionIdentifier)
    }

    /// No two versions in the plan may describe the same store.
    ///
    /// SwiftData tells versions apart by a checksum of their model shapes. Two
    /// versions with the same shapes are indistinguishable, and a staged
    /// migration over them traps on launch — which is what build 16 did, for
    /// everyone. The plan then listed V1–V5 (identical, because they only ever
    /// added columns to shared classes) and V9 = V10 (the same mistake again).
    /// This compares every entity's property names per version, which is
    /// enough to have caught both.
    func testEveryVersionInThePlanIsDistinct() {
        let shapes = PersonalAssistantMigrationPlan.schemas.map { version -> String in
            Schema(version.models, version: version.versionIdentifier).entities
                .map { entity -> String in
                    let names = entity.properties.map { $0.name }.sorted()
                    return entity.name + "(" + names.joined(separator: ",") + ")"
                }
                .sorted()
                .joined(separator: ";")
        }
        XCTAssertEqual(
            Set(shapes).count,
            shapes.count,
            "two versions describe the same store; SwiftData cannot tell them apart and traps"
        )
    }

    /// Every model has to be listed, or its table is simply absent and the
    /// first write to it fails at runtime rather than here.
    func testEveryModelIsRegistered() {
        let names = Set(PersonalAssistantSchemaV1.models.map { String(describing: $0) })
        XCTAssertEqual(
            names,
            [
                "SDConversation",
                "SDMessage",
                "SDActionPlan",
                "SDAction",
                "SDToolResult",
                "SDMemory",
                "SDTask",
                "SDReminderPlan",
                "SDReminderStage",
                "SDAssistantSettings",
                "SDUserProfile",
            ]
        )
    }

    /// The container opens at the newest version the plan knows about.
    ///
    /// Compared against the migration plan rather than a version literal: a
    /// hardcoded number here is a test that has to be edited every time the
    /// schema moves, and therefore one that eventually says something false.
    func testTheContainerUsesTheNewestVersionedSchema() throws {
        let container = try AssistantPersistenceContainer.make(location: .inMemory)
        let newest = PersonalAssistantMigrationPlan.schemas.last

        XCTAssertNotNil(newest)
        XCTAssertEqual(container.schema.version, newest?.versionIdentifier)
    }

    /// Reopening a store must not migrate, reset or otherwise disturb it.
    func testReopeningAnExistingStoreKeepsItsContents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("store.sqlite")

        let id = UUID()
        let first = ModelContext(try AssistantPersistenceContainer.make(location: .file(url)))
        first.insert(
            SDMemory(
                id: id,
                kindRaw: "fact",
                content: "probe",
                salience: 0.5,
                tags: [],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                lastUsedAt: nil,
                sourceRaw: "user"
            )
        )
        try first.save()

        let second = ModelContext(try AssistantPersistenceContainer.make(location: .file(url)))
        let reloaded = try second.fetch(FetchDescriptor<SDMemory>())
        XCTAssertEqual(reloaded.map(\.id), [id])
        XCTAssertEqual(reloaded.first?.content, "probe")
    }
}

#endif
