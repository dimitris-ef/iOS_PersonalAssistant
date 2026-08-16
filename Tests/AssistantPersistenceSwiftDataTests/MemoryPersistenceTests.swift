#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import XCTest

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class MemoryPersistenceTests: PersistenceTestCase {

    func testSavesAndReloadsAMemory() async throws {
        let memory = MemoryItem(
            kind: .routine,
            content: "It takes me 30 minutes to drive to work",
            salience: 0.8,
            tags: ["commute", "work"],
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate,
            lastUsedAt: Self.referenceDate.addingTimeInterval(60),
            source: .user
        )
        try await repositories.memories.store(memory)

        try relaunch()

        let loaded = try await repositories.memories.item(id: memory.id)
        let loaded = try XCTUnwrap(loaded)
        XCTAssertEqual(loaded, memory)
    }

    /// The category is what tells the assistant a statement is a routine rather
    /// than a passing fact, which changes how it plans. Losing it would be a
    /// quiet behavioural regression, not an obvious data loss.
    func testEveryCategorySurvives() async throws {
        for kind in MemoryKind.allCases {
            let memory = MemoryItem(kind: kind, content: "c", createdAt: Self.referenceDate)
            try await repositories.memories.store(memory)
            let loaded = try await repositories.memories.item(id: memory.id)
            let loaded = try XCTUnwrap(loaded)
            XCTAssertEqual(loaded.kind, kind)
        }
    }

    func testMemoriesAreReturnedOldestFirst() async throws {
        let first = MemoryItem(kind: .fact, content: "one", createdAt: Self.referenceDate)
        let second = MemoryItem(
            kind: .fact,
            content: "two",
            createdAt: Self.referenceDate.addingTimeInterval(60)
        )
        try await repositories.memories.store(second)
        try await repositories.memories.store(first)

        try relaunch()

        let loaded = try await repositories.memories.all().map(\.content)
        XCTAssertEqual(loaded, ["one", "two"])
    }

    // MARK: Updating

    func testEditingAMemoryOverwritesIt() async throws {
        var memory = MemoryItem(
            kind: .fact,
            content: "I take the bus",
            createdAt: Self.referenceDate
        )
        try await repositories.memories.store(memory)

        memory.content = "I drive"
        memory.kind = .routine
        memory.tags = ["commute"]
        memory.updatedAt = Self.referenceDate.addingTimeInterval(120)
        try await repositories.memories.store(memory)

        try relaunch()

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 1, "editing must not leave the old version behind")
        XCTAssertEqual(all.first?.content, "I drive")
        XCTAssertEqual(all.first?.kind, .routine)
        XCTAssertEqual(all.first?.tags, ["commute"])
    }

    // MARK: Deleting

    func testDeletingAMemoryRemovesIt() async throws {
        let memory = MemoryItem(kind: .fact, content: "forget me", createdAt: Self.referenceDate)
        try await repositories.memories.store(memory)
        try await repositories.memories.delete(id: memory.id)

        try relaunch()

        let reloaded = try await repositories.memories.item(id: memory.id)
        let remaining = try await repositories.memories.all()
        XCTAssertNil(reloaded)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: Search

    func testSearchRanksTheSameWayTheInMemoryBackendDoes() async throws {
        let items = [
            MemoryItem(
                kind: .place,
                content: "Work is thirty minutes away by bus",
                salience: 0.5,
                tags: ["commute"],
                createdAt: Self.referenceDate
            ),
            MemoryItem(
                kind: .person,
                content: "My dentist is Dr Alvarez",
                salience: 0.5,
                createdAt: Self.referenceDate.addingTimeInterval(60)
            ),
            MemoryItem(
                kind: .routine,
                content: "I need thirty minutes to get ready",
                salience: 0.9,
                createdAt: Self.referenceDate.addingTimeInterval(120)
            ),
        ]
        for item in items { try await repositories.memories.store(item) }

        let query = MemoryQuery(text: "how long to get ready", limit: 5)

        // The same query against the in-memory backend, which is the reference
        // implementation for these semantics. Two backends that rank memories
        // differently would mean the assistant recalls different things
        // depending on where it happens to be running.
        let reference = AssistantRepositories.ephemeral()
        for item in items { try await reference.memories.store(item) }

        let stored = try await repositories.memories.search(query)
        let expected = try await reference.memories.search(query)

        XCTAssertEqual(stored.map(\.id), expected.map(\.id))
        XCTAssertFalse(stored.isEmpty)
    }

    func testSearchFiltersByKind() async throws {
        let routine = MemoryItem(kind: .routine, content: "a", createdAt: Self.referenceDate)
        let fact = MemoryItem(kind: .fact, content: "b", createdAt: Self.referenceDate)
        try await repositories.memories.store(routine)
        try await repositories.memories.store(fact)

        let found = try await repositories.memories.search(MemoryQuery(kinds: [.routine]))
        XCTAssertEqual(found.map(\.id), [routine.id])
    }
}

#endif
