import AssistantCore
import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory
import XCTest

/// A deterministic encoder whose version and availability a test can control.
///
/// It delegates the actual vectors to `LexiconSemanticEncoder`, so what it fakes
/// is only the two things a test needs to steer — whether encoding works at all,
/// and which encoder identity the vectors claim to come from. Faking the vectors
/// themselves would make every ranking assertion a statement about the fake.
private struct ControllableEncoder: SemanticEncoder {
    var identity: SemanticEncoderIdentity
    var available: Bool = true
    /// Counts encodings, so "did this recompute?" is answerable directly.
    let counter: EncodeCounter

    init(version: Int = 1, available: Bool = true, counter: EncodeCounter = EncodeCounter()) {
        self.identity = SemanticEncoderIdentity(providerID: "test.controllable", version: version)
        self.available = available
        self.counter = counter
    }

    var isAvailable: Bool { get async { available } }

    func embedding(for text: String) async throws -> SemanticVector {
        guard available else {
            throw SemanticEncodingError.unavailable(reason: "switched off for this test")
        }
        await counter.record(text)
        let vector = LexiconSemanticEncoder.vector(for: text)
        guard !vector.isEmpty else { throw SemanticEncodingError.emptyText }
        return vector
    }
}

private actor EncodeCounter {
    private(set) var texts: [String] = []
    var count: Int { texts.count }
    func record(_ text: String) { texts.append(text) }
    func reset() { texts.removeAll() }
}

/// Semantic memory wired to real repositories.
///
/// `SemanticRetrievalTests` covers the ranking policy. This covers the plumbing:
/// that vectors are cached and reused, that an edit invalidates them, that an
/// encoder version change is absorbed without losing anybody's memories, and
/// that every one of those paths degrades to lexical ranking rather than
/// breaking.
final class SemanticMemoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_078_400)

    private func makeService(
        _ repositories: AssistantRepositories,
        encoder: (any SemanticEncoder)?
    ) -> MemoryRetrievalService {
        MemoryRetrievalService(
            repository: repositories.memories,
            relations: repositories.memoryRelations,
            embeddings: repositories.memoryEmbeddings,
            encoder: encoder
        )
    }

    private func memoryService(
        _ repositories: AssistantRepositories,
        encoder: (any SemanticEncoder)?
    ) -> MemoryService {
        MemoryService(
            repository: repositories.memories,
            relations: repositories.memoryRelations,
            embeddings: repositories.memoryEmbeddings,
            encoder: encoder,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    private func memory(
        _ content: String,
        kind: MemoryKind = .routine,
        source: MemorySource = .user
    ) -> MemoryItem {
        MemoryItem(kind: kind, content: content, createdAt: now, source: source)
    }

    // MARK: Retrieval end to end

    func testSemanticRetrievalFindsAMemoryWithLittleWordOverlap() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = memoryService(repositories, encoder: ControllableEncoder())
        try await service.remember(memory("It usually takes me about half an hour to drive to work."))
        try await service.remember(memory("I like Sony cameras.", kind: .preference))

        let retrieval = makeService(repositories, encoder: ControllableEncoder())
        let selected = try await retrieval.relevantMemories(
            for: "How long should I allow for my commute?",
            now: now
        )

        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected[0].content.contains("drive to work"))
    }

    // MARK: Fallback

    /// Section 5 and 71. Memory must never become unusable because encoding
    /// failed.
    func testRetrievalStillWorksWhenTheEncoderIsUnavailable() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = memoryService(repositories, encoder: nil)
        try await service.remember(memory("My commute to work takes thirty minutes."))

        let retrieval = makeService(
            repositories,
            encoder: ControllableEncoder(available: false)
        )
        let result = try await retrieval.retrieve(query: "How long is my commute to work?", now: now)

        XCTAssertFalse(result.metrics.usedSemantics)
        XCTAssertEqual(result.selection.count, 1, "lexical ranking should still find it")
    }

    func testRetrievalWorksWithNoEncoderComposedInAtAll() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = memoryService(repositories, encoder: nil)
        try await service.remember(memory("My commute to work takes thirty minutes."))

        let selected = try await makeService(repositories, encoder: nil)
            .relevantMemories(for: "How long is my commute to work?", now: now)
        XCTAssertEqual(selected.count, 1)
    }

    // MARK: The cache

    func testAVectorIsComputedOnceAndReusedAfterwards() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let counter = EncodeCounter()
        let encoder = ControllableEncoder(counter: counter)

        try await memoryService(repositories, encoder: encoder)
            .remember(memory("My commute to work takes thirty minutes."))

        let all = try await repositories.memories.all()
        let storedID = try XCTUnwrap(all.first?.id)
        let stored = try await repositories.memoryEmbeddings.embedding(for: storedID)
        XCTAssertNotNil(stored, "writing a memory should index it")

        await counter.reset()
        let retrieval = makeService(repositories, encoder: encoder)
        _ = try await retrieval.relevantMemories(for: "How long is my commute?", now: now)
        _ = try await retrieval.relevantMemories(for: "How long is my commute?", now: now)

        // The query, encoded once and cached for the turn — and the memory not
        // re-encoded at all.
        let texts = await counter.texts
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts.first, "How long is my commute?")
    }

    /// Section 72. Editing the text must throw the vector away: it describes
    /// something the user no longer believes.
    func testEditingAMemoryRegeneratesItsVector() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let encoder = ControllableEncoder()
        let service = memoryService(repositories, encoder: encoder)

        try await service.remember(memory("Work commute takes 30 minutes."))
        let all = try await repositories.memories.all()
        let original = try XCTUnwrap(all.first)
        let loadedFirst = try await repositories.memoryEmbeddings.embedding(for: original.id)
        let firstVector = try XCTUnwrap(loadedFirst)

        _ = try await service.update(
            MemoryItem(
                id: original.id,
                kind: original.kind,
                content: "Work commute takes 45 minutes.",
                createdAt: original.createdAt,
                source: original.source
            )
        )

        let loadedSecond = try await repositories.memoryEmbeddings.embedding(for: original.id)
        let secondVector = try XCTUnwrap(loadedSecond)
        XCTAssertNotEqual(firstVector.contentHash, secondVector.contentHash)
        XCTAssertTrue(
            secondVector.isValid(
                for: MemoryContentHash.hash("Work commute takes 45 minutes."),
                encoder: encoder.identity
            )
        )
    }

    /// Section 73. A new encoder invalidates every stored vector at a stroke —
    /// and nobody's memories are deleted for it.
    func testAnEncoderVersionChangeInvalidatesVectorsWithoutLosingMemories() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let versionOne = ControllableEncoder(version: 1)
        try await memoryService(repositories, encoder: versionOne)
            .remember(memory("Work commute takes 30 minutes."))

        let all = try await repositories.memories.all()
        let stored = try XCTUnwrap(all.first)
        let loadedCache = try await repositories.memoryEmbeddings.embedding(for: stored.id)
        let cached = try XCTUnwrap(loadedCache)
        let hash = MemoryContentHash.hash(stored.content)

        let versionTwo = ControllableEncoder(version: 2)
        XCTAssertTrue(cached.isValid(for: hash, encoder: versionOne.identity))
        XCTAssertFalse(
            cached.isValid(for: hash, encoder: versionTwo.identity),
            "a vector from another encoder is in a different space"
        )

        // The memory itself is untouched, and maintenance regenerates the
        // vector lazily rather than a migration doing it eagerly.
        let maintenance = MemoryMaintenanceService(
            repositories: repositories,
            encoder: versionTwo,
            dateProvider: FixedDateProvider(now: now)
        )
        let generated = try await maintenance.backfillEmbeddings()

        XCTAssertEqual(generated, 1)
        let loadedRefreshed = try await repositories.memoryEmbeddings.embedding(for: stored.id)
        let refreshed = try XCTUnwrap(loadedRefreshed)
        XCTAssertTrue(refreshed.isValid(for: hash, encoder: versionTwo.identity))

        let afterwards = try await repositories.memories.all()
        XCTAssertEqual(afterwards.count, 1)
        XCTAssertEqual(afterwards.first?.content, stored.content)
    }

    // MARK: Provider independence

    /// Section 88. The encoder is not the conversational provider, and nothing
    /// about ranking reads which one is selected — so this asserts the property
    /// directly: the same store and the same question give the same answer, and
    /// there is no provider parameter anywhere in the path to vary.
    func testRetrievalIsIdenticalRegardlessOfWhichProviderIsConfigured() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = memoryService(repositories, encoder: ControllableEncoder())
        try await service.remember(memory("It takes me half an hour to drive to work."))
        try await service.remember(memory("I need forty-five minutes to get ready."))
        try await service.remember(memory("I like Sony cameras.", kind: .preference))

        var settings = try await repositories.settings.settings()
        var results: [[MemoryItem.ID]] = []

        for provider in ["remote.openai-compatible", "apple.foundation-models", "dev.scripted"] {
            settings.preferredProviderID = AIProviderIdentifier(provider)
            try await repositories.settings.update(settings)

            let selected = try await makeService(repositories, encoder: ControllableEncoder())
                .relevantMemories(for: "When should I leave for work?", now: now)
            results.append(selected.map(\.id))
        }

        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[1], results[2])
        XCTAssertFalse(results[0].isEmpty)
    }

    // MARK: Context assembly

    /// Section 92. The whole path, through the layer the turn pipeline uses.
    func testContextAssemblyIncludesRelevantMemoriesAndExcludesTheRest() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let encoder = ControllableEncoder()
        let service = memoryService(repositories, encoder: encoder)
        try await service.remember(memory("It usually takes me half an hour to drive to work."))
        try await service.remember(memory("I like Sony cameras.", kind: .preference))
        try await service.remember(memory("Rent is due on the first.", kind: .recurringCommitment))

        let assembler = ContextAssembler(
            repositories: repositories,
            dateProvider: FixedDateProvider(now: now),
            semanticEncoder: encoder
        )
        let conversation = Conversation(createdAt: now)
        try await repositories.conversations.save(conversation)

        let context = try await assembler.assemble(
            conversation: conversation,
            query: "How much travel time should I allow for my commute?",
            calendarEvents: []
        )

        XCTAssertEqual(context.relevantMemories.count, 1)
        XCTAssertTrue(context.relevantMemories[0].content.contains("drive to work"))

        let settings = try await repositories.settings.settings()
        XCTAssertLessThanOrEqual(context.relevantMemories.count, settings.memoryContextLimit)
    }
}
