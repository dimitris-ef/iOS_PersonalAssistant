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

    func testTheMigrationPlanKnowsAboutV1() {
        XCTAssertEqual(PersonalAssistantMigrationPlan.schemas.count, 1)
        // No stages yet, and that is correct for a first version — the plan is
        // in place so the next one has somewhere to go.
        XCTAssertTrue(PersonalAssistantMigrationPlan.stages.isEmpty)
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

    func testTheContainerUsesTheVersionedSchema() throws {
        let container = try AssistantPersistenceContainer.make(location: .inMemory)
        XCTAssertEqual(container.schema.version, Schema.Version(1, 0, 0))
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
