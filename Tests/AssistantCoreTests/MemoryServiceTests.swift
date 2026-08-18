import AssistantCore
import AssistantDomain
import AssistantPersistence
import PersonalMemory
import XCTest

/// Writing memories: defaults, duplicates, conflicts, edits, deletes.
final class MemoryServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeService(_ repositories: AssistantRepositories) -> MemoryService {
        MemoryService(
            repository: repositories.memories,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    // MARK: Defaults

    func testAManualMemoryIsTrustedByDefault() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let result = try await service.remember(
            MemoryItem(kind: .routine, content: "I go to bed at midnight", createdAt: now, source: .manual)
        )

        XCTAssertEqual(result.effect, .stored)
        XCTAssertEqual(result.memory.source, .manual)
        XCTAssertEqual(result.memory.confidence, MemorySource.manual.defaultConfidence)
        XCTAssertGreaterThan(result.memory.confidence, MemorySource.assistant.defaultConfidence)
    }

    func testAnInferredMemoryIsTrustedLess() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let result = try await service.remember(
            MemoryItem(kind: .routine, content: "Probably prefers evening workouts", createdAt: now, source: .assistant)
        )
        XCTAssertLessThan(result.memory.confidence, MemorySource.user.defaultConfidence)
    }

    func testAnEmptyMemoryIsRejected() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        do {
            _ = try await service.remember(
                MemoryItem(kind: .fact, content: "   ", createdAt: now, source: .user)
            )
            XCTFail("Expected empty content to be rejected")
        } catch let error as MemoryServiceError {
            XCTAssertEqual(error, .emptyContent)
        }
    }

    // MARK: Duplicates

    func testStoringTheSameMemoryTwiceKeepsOneRecord() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)
        let content = "I need 45 minutes to get ready for work"

        let first = try await service.remember(
            MemoryItem(kind: .routine, content: content, createdAt: now, source: .user)
        )
        let second = try await service.remember(
            MemoryItem(kind: .routine, content: content, createdAt: now, source: .user)
        )

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 1, "the same fact must not accumulate")
        XCTAssertEqual(second.effect, .merged(into: first.memory.id))
        XCTAssertEqual(all.first?.id, first.memory.id, "the identifier is stable")
    }

    func testAParaphraseIsFoldedIntoTheExistingMemory() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let first = try await service.remember(
            MemoryItem(
                kind: .place,
                content: "It takes me 30 minutes to drive to work",
                createdAt: now,
                source: .user
            )
        )
        _ = try await service.remember(
            MemoryItem(
                kind: .place,
                content: "My commute to work is roughly half an hour",
                createdAt: now,
                source: .assistant
            )
        )

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, first.memory.id)
        // The explicit statement is not overwritten by the assistant's phrasing.
        XCTAssertEqual(all.first?.content, "It takes me 30 minutes to drive to work")
    }

    /// The protection against over-eager merging.
    func testAQualifiedVariantIsStoredSeparately() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        _ = try await service.remember(
            MemoryItem(kind: .place, content: "Commute takes 30 minutes normally", createdAt: now, source: .user)
        )
        _ = try await service.remember(
            MemoryItem(
                kind: .place,
                content: "Commute takes 45 minutes during rush hour",
                createdAt: now,
                source: .user
            )
        )

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 2, "both are true and describe different situations")
    }

    // MARK: Conflicts

    func testANewerExplicitStatementCorrectsTheStoredOne() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let original = try await service.remember(
            MemoryItem(kind: .place, content: "My commute takes 20 minutes", createdAt: now, source: .assistant)
        )
        let correction = try await service.remember(
            MemoryItem(kind: .place, content: "My commute takes 30 minutes", createdAt: now, source: .user)
        )

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 1, "a correction replaces rather than accumulates")
        XCTAssertEqual(all.first?.id, original.memory.id, "the record keeps its identity")
        XCTAssertEqual(all.first?.content, "My commute takes 30 minutes")
        XCTAssertEqual(correction.effect, .replaced(original.memory.id))
    }

    func testAWeakerContradictionIsKeptAlongsideRatherThanOverwriting() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let stated = try await service.remember(
            MemoryItem(kind: .place, content: "My commute takes 30 minutes", createdAt: now, source: .user)
        )
        let guessed = try await service.remember(
            MemoryItem(kind: .place, content: "My commute takes 20 minutes", createdAt: now, source: .assistant)
        )

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 2, "a guess must not overwrite what the user said")
        XCTAssertEqual(guessed.effect, .keptAlongsideConflict(with: stated.memory.id))
        // Both are visible in the Memory screen, where the user can settle it.
        XCTAssertTrue(all.contains { $0.content == "My commute takes 30 minutes" })
    }

    // MARK: Edits and deletes

    func testAUserEditUpdatesTheSameRecordAndIsTrusted() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let stored = try await service.remember(
            MemoryItem(kind: .routine, content: "Getting ready takes 30 minutes", createdAt: now, source: .assistant)
        )

        var edited = stored.memory
        edited.content = "Getting ready takes 45 minutes"
        let updated = try await service.update(edited)

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 1, "editing must not create a second memory")
        XCTAssertEqual(updated.id, stored.memory.id, "the identifier is stable")
        XCTAssertEqual(all.first?.content, "Getting ready takes 45 minutes")
        // The user is the authority on their own life.
        XCTAssertEqual(all.first?.source, .manual)
        XCTAssertEqual(all.first?.confidence, MemorySource.manual.defaultConfidence)
        XCTAssertEqual(all.first?.updatedAt, now)
    }

    /// An edit is never deduplicated: the user is changing this exact record.
    func testAnEditThatResemblesAnotherMemoryStillSaves() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        _ = try await service.remember(
            MemoryItem(kind: .place, content: "Work is 30 minutes from home", createdAt: now, source: .user)
        )
        let other = try await service.remember(
            MemoryItem(kind: .person, content: "Anna works nearby", createdAt: now, source: .user)
        )

        var edited = other.memory
        edited.content = "Work is 30 minutes from home"
        _ = try await service.update(edited)

        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, 2, "the edited record still exists in its own right")
        XCTAssertTrue(all.contains { $0.id == other.memory.id })
    }

    func testForgettingRemovesTheMemory() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)

        let stored = try await service.remember(
            MemoryItem(kind: .fact, content: "Something forgettable", createdAt: now, source: .user)
        )
        try await service.forget(id: stored.memory.id)

        let all = try await repositories.memories.all()
        XCTAssertTrue(all.isEmpty)

        let fetched = try await repositories.memories.item(id: stored.memory.id)
        XCTAssertNil(fetched)
    }

    /// A deleted memory must not come back through retrieval.
    func testADeletedMemoryIsNeverRetrieved() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(repositories)
        let retrieval = MemoryRetrievalService(repository: repositories.memories)

        let stored = try await service.remember(
            MemoryItem(
                kind: .place,
                content: "Work is 30 minutes from home",
                createdAt: now,
                source: .user
            )
        )
        let before = try await retrieval.relevantMemories(for: "how far is work", now: now)
        XCTAssertFalse(before.isEmpty)

        try await service.forget(id: stored.memory.id)

        let after = try await retrieval.relevantMemories(for: "how far is work", now: now)
        XCTAssertTrue(after.isEmpty, "a forgotten memory must not be recalled")
    }
}
