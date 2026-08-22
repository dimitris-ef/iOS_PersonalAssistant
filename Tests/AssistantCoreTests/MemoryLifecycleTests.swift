import AssistantCore
import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory
import XCTest

/// Contradictions, corrections, consolidation and forgetting — through the
/// services, against real repositories.
final class MemoryLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_078_400)

    private func makeService(_ repositories: AssistantRepositories) -> MemoryService {
        MemoryService(
            repository: repositories.memories,
            relations: repositories.memoryRelations,
            embeddings: repositories.memoryEmbeddings,
            encoder: LexiconSemanticEncoder(),
            dateProvider: FixedDateProvider(now: now)
        )
    }

    private func maintenance(_ repositories: AssistantRepositories) -> MemoryMaintenanceService {
        MemoryMaintenanceService(
            repositories: repositories,
            encoder: LexiconSemanticEncoder(),
            dateProvider: FixedDateProvider(now: now)
        )
    }

    private func memory(
        _ content: String,
        kind: MemoryKind = .routine,
        source: MemorySource = .user,
        confidence: Double? = nil
    ) -> MemoryItem {
        MemoryItem(kind: kind, content: content, createdAt: now, source: source, confidence: confidence)
    }

    // MARK: Contradiction

    /// Section 81. A new explicit statement supersedes an older inference about
    /// the same thing — and retrieval uses the new one.
    func testANewExplicitStatementReplacesAnOlderInference() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        try await service.remember(
            memory("I prefer morning workouts.", kind: .preference, source: .assistant, confidence: 0.5)
        )
        let result = try await service.remember(
            memory("I prefer working out at night.", kind: .preference, source: .user)
        )

        XCTAssertEqual(result.memory.content, "I prefer working out at night.")
        XCTAssertEqual(result.memory.source, .user)
        XCTAssertEqual(result.memory.lifecycle, .active)

        let stored = try await repositories.memories.all()
        let retrievable = stored.filter(\.isRetrievable)
        XCTAssertEqual(retrievable.count, 1)
        XCTAssertTrue(retrievable[0].content.contains("night"))
    }

    /// Section 39 and 82. Weaker evidence does not overwrite what the user
    /// said — it is kept, marked unresolved, and linked to what it disagrees
    /// with so the Memory screen can show them together.
    func testAWeakerDisagreementIsKeptAsUnresolvedAndLinked() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let stated = try await service.remember(
            memory("My commute takes 30 minutes.", source: .user)
        )
        let guessed = try await service.remember(
            memory("My commute takes 45 minutes.", source: .assistant, confidence: 0.4)
        )

        XCTAssertEqual(guessed.memory.lifecycle, .conflicting)

        // Both remain inspectable — the whole point of not deleting.
        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 2)

        let edges = try await repositories.memoryRelations.relations(for: guessed.memory.id)
        XCTAssertTrue(
            edges.contains { $0.type == .contradicts && $0.target == stated.memory.id }
        )
    }

    /// And the unresolved one stays out of prompts while the settled one does
    /// not.
    func testAnUnresolvedMemoryIsNotRetrieved() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)
        try await service.remember(memory("My commute takes 30 minutes.", source: .user))
        try await service.remember(
            memory("My commute takes 45 minutes.", source: .assistant, confidence: 0.4)
        )

        let retrieval = MemoryRetrievalService(
            repository: repositories.memories,
            relations: repositories.memoryRelations,
            embeddings: repositories.memoryEmbeddings,
            encoder: LexiconSemanticEncoder()
        )
        let selected = try await retrieval.relevantMemories(for: "How long is my commute?", now: now)

        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected[0].content.contains("30"))
    }

    // MARK: User correction

    /// Section 41 and 90. An edit is authoritative, protected from maintenance,
    /// and does not create a second row.
    func testAUserEditIsAuthoritativeAndCreatesNoDuplicate() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)
        let original = try await service.remember(memory("Work commute takes 30 minutes."))

        var edited = original.memory
        edited.content = "Work commute takes 40 minutes."
        let updated = try await service.update(edited)

        XCTAssertEqual(updated.id, original.memory.id)
        XCTAssertEqual(updated.source, .manual)
        XCTAssertTrue(updated.isProtected)
        XCTAssertEqual(updated.lifecycle, .active)

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.content, "Work commute takes 40 minutes.")
    }

    /// Section 98. Restoring is explicit interest, so the memory comes back
    /// protected — the next maintenance pass must not quietly re-archive it.
    func testRestoringAnArchivedMemoryBringsItBackProtected() async throws {
        let repositories = AssistantRepositories.ephemeral()
        var archived = memory("A café the assistant once guessed at.", kind: .place, source: .assistant)
        archived.lifecycle = .archived
        try await repositories.memories.store(archived)

        let restored = try await makeService(repositories).restore(id: archived.id)

        XCTAssertEqual(restored.lifecycle, .active)
        XCTAssertTrue(restored.isProtected)
    }

    // MARK: Deletion

    /// Section 52 and 91. The user's delete wins completely: the memory, its
    /// vector and its edges all go, and nothing puts it back.
    func testDeletingAMemoryRemovesItsVectorAndItsEdges() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)
        let stated = try await service.remember(memory("My commute takes 30 minutes.", source: .user))
        try await service.remember(
            memory("My commute takes 45 minutes.", source: .assistant, confidence: 0.4)
        )

        try await service.forget(id: stated.memory.id)

        let cached = try await repositories.memoryEmbeddings.embedding(for: stated.memory.id)
        XCTAssertNil(cached)

        let edges = try await repositories.memoryRelations.relations(for: stated.memory.id)
        XCTAssertTrue(edges.isEmpty)

        let remaining = try await repositories.memories.all()
        XCTAssertFalse(remaining.contains { $0.id == stated.memory.id })

        // And maintenance does not resurrect it.
        _ = try await maintenance(repositories).run()
        let afterMaintenance = try await repositories.memories.all()
        XCTAssertFalse(afterMaintenance.contains { $0.id == stated.memory.id })
    }

    // MARK: Maintenance

    /// Section 78. Three equivalent statements become one active fact, with the
    /// sources kept and linked.
    func testMaintenanceConsolidatesEquivalentMemories() async throws {
        let repositories = AssistantRepositories.ephemeral()
        // Stored directly rather than through the write path, because the write
        // path would already have folded them — which is the point: what
        // reaches consolidation is what deduplication could not see at the time.
        for content in [
            "I take about 30 minutes to get to work.",
            "My commute is usually half an hour.",
            "It normally takes around 30 minutes to drive to work.",
        ] {
            try await repositories.memories.store(
                MemoryItem(
                    kind: .routine,
                    content: content,
                    createdAt: now,
                    source: .user,
                    entityKeys: MemoryEntityExtractor.keys(for: content, kind: .routine)
                )
            )
        }

        let report = try await maintenance(repositories).run()
        XCTAssertEqual(report.consolidations, 1)
        XCTAssertEqual(report.superseded, 3)

        let all = try await repositories.memories.all()
        let active = all.filter(\.isRetrievable)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.consolidatedFrom.count, 3)
        // Nothing destroyed: the sources are still there, superseded.
        XCTAssertEqual(all.count, 4)
    }

    /// Section 79 and 50. Running maintenance twice must not produce a second
    /// consolidated memory, nor duplicate the relations.
    func testMaintenanceIsIdempotent() async throws {
        let repositories = AssistantRepositories.ephemeral()
        for content in [
            "I take about 30 minutes to get to work.",
            "My commute is usually half an hour.",
        ] {
            try await repositories.memories.store(
                MemoryItem(
                    kind: .routine,
                    content: content,
                    createdAt: now,
                    source: .user,
                    entityKeys: MemoryEntityExtractor.keys(for: content, kind: .routine)
                )
            )
        }

        let service = maintenance(repositories)
        _ = try await service.run()
        let afterFirst = try await repositories.memories.all()
        let edgesAfterFirst = try await repositories.memoryRelations.all()

        let second = try await service.run()
        let afterSecond = try await repositories.memories.all()
        let edgesAfterSecond = try await repositories.memoryRelations.all()

        XCTAssertEqual(second.consolidations, 0)
        XCTAssertEqual(afterFirst.count, afterSecond.count)
        XCTAssertEqual(edgesAfterFirst.count, edgesAfterSecond.count)
    }

    /// Section 86. Aging moves a weak old inference out of retrieval without
    /// deleting it, and the Memory screen can still ask for it.
    func testAgingRemovesAWeakInferenceFromRetrievalButNotFromTheStore() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let ancient = MemoryItem(
            kind: .fact,
            content: "The assistant once guessed a preferred café.",
            salience: 0.1,
            createdAt: now.addingTimeInterval(-TimeSpan.days(600)),
            source: .assistant,
            confidence: 0.4
        )
        try await repositories.memories.store(ancient)

        let report = try await maintenance(repositories).run()
        XCTAssertEqual(report.archived, 1)

        let stored = try await repositories.memories.all()
        XCTAssertEqual(stored.count, 1, "archiving is not deleting")
        XCTAssertEqual(stored.first?.lifecycle, .archived)

        let retrieval = MemoryRetrievalService(
            repository: repositories.memories,
            relations: repositories.memoryRelations,
            embeddings: repositories.memoryEmbeddings,
            encoder: LexiconSemanticEncoder()
        )
        let selected = try await retrieval.relevantMemories(for: "Which café do I like?", now: now)
        XCTAssertTrue(selected.isEmpty)

        // But the store still answers for it when asked directly, which is what
        // makes the Memory screen able to show it.
        let inspected = try await repositories.memories.item(id: ancient.id)
        XCTAssertNotNil(inspected)
    }

    /// Section 74. The existing exact-duplicate behaviour is unchanged.
    func testAnExactDuplicateStillMergesRatherThanAddingARow() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let first = try await service.remember(memory("Rent is due on the first.", kind: .recurringCommitment))
        let second = try await service.remember(memory("Rent is due on the first.", kind: .recurringCommitment))

        XCTAssertEqual(second.effect, .merged(into: first.memory.id))
        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 1)
    }
}
