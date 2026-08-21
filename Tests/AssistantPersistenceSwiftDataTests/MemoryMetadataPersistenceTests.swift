#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import SwiftData
import XCTest

/// The new memory metadata, through the real store and back.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class MemoryMetadataPersistenceTests: PersistenceTestCase {

    func testConfidenceAndSourceSurviveARelaunch() async throws {
        let memory = MemoryItem(
            kind: .routine,
            content: "I usually need 45 minutes to get ready for work",
            salience: 0.82,
            tags: ["morning", "work"],
            createdAt: Self.referenceDate,
            source: .observation,
            confidence: 0.71
        )
        try await repositories.memories.store(memory)

        try relaunch()

        let reloaded = try await repositories.memories.item(id: memory.id)
        let loaded = try XCTUnwrap(reloaded)

        XCTAssertEqual(loaded, memory)
        XCTAssertEqual(loaded.confidence, 0.71)
        XCTAssertEqual(loaded.source, .observation)
        XCTAssertEqual(loaded.salience, 0.82)
        XCTAssertEqual(loaded.kind, .routine)
        XCTAssertEqual(loaded.tags, ["morning", "work"])
    }

    func testEverySourceRoundTrips() async throws {
        for source in MemorySource.allCases {
            let memory = MemoryItem(
                kind: .fact,
                content: "content for \(source.rawValue)",
                createdAt: Self.referenceDate,
                source: source
            )
            try await repositories.memories.store(memory)

            let reloaded = try await repositories.memories.item(id: memory.id)
            XCTAssertEqual(reloaded?.source, source)
            XCTAssertEqual(reloaded?.confidence, source.defaultConfidence)
        }
    }

    /// A memory stored before schema V3 has no recorded confidence.
    ///
    /// It must still load, still rank, and keep the trust its source implies —
    /// treating everything from before this feature as doubtful would quietly
    /// discard what the assistant already knew about someone.
    func testAMemoryWithoutRecordedConfidenceGetsASafeDefault() async throws {
        let id = UUID()

        // Written the way a pre-V3 row exists on disk: no confidence column.
        let persistence = AssistantPersistenceActor(modelContainer: store.container)
        try await persistence.mutate(entity: "memory") { context in
            context.insert(
                SDMemory(
                    id: id,
                    kindRaw: MemoryKind.routine.rawValue,
                    content: "Work is 30 minutes from home",
                    salience: 0.6,
                    tags: [],
                    createdAt: Self.referenceDate,
                    updatedAt: Self.referenceDate,
                    lastUsedAt: nil,
                    sourceRaw: MemorySource.user.rawValue,
                    confidenceValue: nil
                )
            )
        }

        try relaunch()

        let reloaded = try await repositories.memories.item(id: MemoryItem.ID(id))
        let loaded = try XCTUnwrap(reloaded, "a legacy memory must still load")

        XCTAssertEqual(loaded.content, "Work is 30 minutes from home")
        XCTAssertEqual(loaded.source, .user)
        // Derived from the source it did record, rather than a blanket value.
        XCTAssertEqual(loaded.confidence, MemorySource.user.defaultConfidence)
        XCTAssertGreaterThan(loaded.confidence, 0.5, "it must not drop out of ranking")
    }

    /// A source string this build does not know is not a reason to lose a
    /// memory.
    func testAnUnknownSourceFallsBackToLegacy() async throws {
        let id = UUID()
        let persistence = AssistantPersistenceActor(modelContainer: store.container)
        try await persistence.mutate(entity: "memory") { context in
            context.insert(
                SDMemory(
                    id: id,
                    kindRaw: MemoryKind.fact.rawValue,
                    content: "Something from a newer build",
                    salience: 0.5,
                    tags: [],
                    createdAt: Self.referenceDate,
                    updatedAt: Self.referenceDate,
                    lastUsedAt: nil,
                    sourceRaw: "somethingNewerKnows",
                    confidenceValue: nil
                )
            )
        }

        try relaunch()

        let reloaded = try await repositories.memories.item(id: MemoryItem.ID(id))
        let loaded = try XCTUnwrap(reloaded)
        XCTAssertEqual(loaded.source, .legacy)
        XCTAssertEqual(loaded.confidence, MemorySource.legacy.defaultConfidence)
    }

    func testEditingAMemoryUpdatesTheSameRowAcrossARelaunch() async throws {
        var memory = MemoryItem(
            kind: .routine,
            content: "Getting ready takes 30 minutes",
            createdAt: Self.referenceDate,
            source: .assistant
        )
        try await repositories.memories.store(memory)

        memory.content = "Getting ready takes 45 minutes"
        memory.source = .manual
        memory.confidence = MemorySource.manual.defaultConfidence
        memory.updatedAt = Self.referenceDate.addingTimeInterval(60)
        try await repositories.memories.store(memory)

        try relaunch()

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 1, "an edit must not leave the old version behind")
        XCTAssertEqual(all.first?.content, "Getting ready takes 45 minutes")
        XCTAssertEqual(all.first?.source, .manual)
        XCTAssertEqual(all.first?.confidence, MemorySource.manual.defaultConfidence)
    }

    func testADeletedMemoryStaysDeleted() async throws {
        let memory = MemoryItem(
            kind: .fact,
            content: "Forget me",
            createdAt: Self.referenceDate,
            source: .user
        )
        try await repositories.memories.store(memory)
        try await repositories.memories.delete(id: memory.id)

        try relaunch()

        let fetched = try await repositories.memories.item(id: memory.id)
        XCTAssertNil(fetched)
        let remaining = try await repositories.memories.all()
        XCTAssertTrue(remaining.isEmpty)

        // And it does not come back through ranked retrieval either.
        let searched = try await repositories.memories.search(
            MemoryQuery(text: "forget", now: Self.referenceDate)
        )
        XCTAssertTrue(searched.isEmpty)
    }

    /// The migration plan is complete and the container opens the newest
    /// version.
    ///
    /// Rewritten from asserting the literal "version 3", which made adding a
    /// schema version fail a test about memory metadata — a false alarm that
    /// teaches people to edit the number and move on. What actually matters is
    /// the *relationship*: every version has a stage into it, and the store the
    /// app opens is the latest one. Those hold at V4 and will hold at V9.
    func testTheMigrationPlanCoversEveryVersion() throws {
        // One stage per hop between consecutive versions. A version added
        // without a stage is a store that cannot be opened after an upgrade,
        // and that is the failure worth asserting against — it survives every
        // future version without editing.
        XCTAssertEqual(
            PersonalAssistantMigrationPlan.stages.count,
            PersonalAssistantMigrationPlan.schemas.count - 1,
            "Every schema version needs a migration stage into it"
        )
        XCTAssertFalse(PersonalAssistantMigrationPlan.schemas.isEmpty)

        // The app opens the newest version, not an older one left behind.
        //
        // The newest version is named concretely rather than read off the end
        // of `schemas`, and not by choice: reading `versionIdentifier` through
        // `any VersionedSchema.Type` **crashes the Swift 6.2 frontend** with a
        // SIL error on `alloc_stack $@opened(…) any VersionedSchema`. Opening
        // an existential metatype to reach a static protocol member is the
        // trigger. So this line costs one edit per schema version, which is
        // the price of compiling.
        XCTAssertEqual(store.container.schema.version, PersonalAssistantSchemaV6.versionIdentifier)
        XCTAssertEqual(PersonalAssistantSchemaV6.versionIdentifier, Schema.Version(6, 0, 0))
    }
}

#endif
