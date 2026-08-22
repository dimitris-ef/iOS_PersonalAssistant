import AssistantDomain
import XCTest
@testable import PersonalMemory

/// Recall by meaning, and everything that must not follow from it.
///
/// ## Why these tests use the real lexicon encoder
///
/// Because a mock that returns "similar" for the pair a test names is a test of
/// the mock. `LexiconSemanticEncoder` is deterministic, offline, and the same
/// code that runs on a device with no Apple model — so an assertion here is an
/// assertion about behaviour somebody will actually get.
final class SemanticRetrievalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_078_400)
    private let ranker = MemoryRanker()

    private func memory(
        _ content: String,
        kind: MemoryKind = .routine,
        source: MemorySource = .user,
        salience: Double = 0.6,
        confidence: Double? = nil,
        ageDays: Double = 10
    ) -> MemoryItem {
        MemoryItem(
            kind: kind,
            content: content,
            salience: salience,
            createdAt: now.addingTimeInterval(-TimeSpan.days(ageDays)),
            source: source,
            confidence: confidence,
            entityKeys: MemoryEntityExtractor.keys(for: content, kind: kind)
        )
    }

    /// Vectors for a set of memories, as the retrieval service would resolve
    /// them.
    private func context(
        query: String,
        memories: [MemoryItem],
        relations: [MemoryRelation] = []
    ) -> MemoryRankingContext {
        var vectors: [MemoryItem.ID: SemanticVector] = [:]
        for memory in memories {
            vectors[memory.id] = LexiconSemanticEncoder.vector(for: memory.content)
        }
        return MemoryRankingContext(
            queryVector: LexiconSemanticEncoder.vector(for: query),
            memoryVectors: vectors,
            relations: relations
        )
    }

    private func select(
        _ memories: [MemoryItem],
        query: String,
        relations: [MemoryRelation] = [],
        semantic: Bool = true
    ) -> [MemoryScoreBreakdown] {
        ranker.select(
            from: memories,
            query: MemoryQuery(text: query, limit: 5, now: now),
            context: semantic
                ? context(query: query, memories: memories, relations: relations)
                : .lexicalOnly
        )
    }

    // MARK: The example this milestone exists for

    /// Section 17 and 118. The query and the memory share almost no content
    /// word; what they share is what they are about.
    func testAMemoryIsFoundByMeaningWhenTheWordsDoNotOverlap() {
        let commute = memory("It usually takes me about half an hour to drive to work.")
        let others = [
            memory("I prefer dark mode.", kind: .preference),
            memory("I usually buy groceries on Saturday.", kind: .recurringCommitment),
            memory("I like Sony cameras.", kind: .preference),
        ]

        let selected = select([commute] + others, query: "How much travel time should I plan for my commute?")

        XCTAssertEqual(selected.first?.memory.id, commute.id)
        // Not merely ranked first — actually selected, and alone. Section 69:
        // testing the order without testing the final set would pass even if
        // every memory were injected.
        XCTAssertEqual(selected.map(\.memory.id), [commute.id])
    }

    /// Section 18, with different wording again.
    func testGettingReadyIsFoundFromAQuestionAboutStartingAShift() {
        let preparation = memory("I usually need about 45 minutes to get ready before work.")
        let others = [
            memory("I like Sony cameras.", kind: .preference),
            memory("Rent is due on the first.", kind: .recurringCommitment),
        ]

        let selected = select([preparation] + others, query: "When should I start preparing for my shift?")
        XCTAssertEqual(selected.map(\.memory.id), [preparation.id])
    }

    /// The lexical channel alone cannot do this, and saying so is the point of
    /// having added the other one.
    func testTheSameQueryFindsNothingWithoutSemantics() {
        let commute = memory("It usually takes me about half an hour to drive to work.")
        let lexicalOnly = select(
            [commute],
            query: "How much travel time should I plan for my commute?",
            semantic: false
        )
        let hybrid = select([commute], query: "How much travel time should I plan for my commute?")

        XCTAssertTrue(lexicalOnly.isEmpty)
        XCTAssertEqual(hybrid.count, 1)
    }

    // MARK: Exclusion

    /// Section 20. A vector model always returns *some* similarity, so "the top
    /// three matches" is never a selection criterion — there are always three.
    func testAnUnrelatedQuestionSelectsNothing() {
        let memories = [
            memory("It usually takes me about half an hour to drive to work."),
            memory("I usually buy groceries on Saturday.", kind: .recurringCommitment),
            memory("My dentist is Dr Alvarez.", kind: .person),
        ]

        XCTAssertTrue(select(memories, query: "What's the weather like?").isEmpty)
    }

    func testManyUnrelatedMemoriesStayOutOfACommuteQuestion() {
        let commute = memory("Work is about thirty minutes away by car.", kind: .place)
        let noise = [
            memory("I like Sony cameras.", kind: .preference),
            memory("I usually buy groceries on Saturday.", kind: .recurringCommitment),
            memory("My sister's birthday is in March.", kind: .person),
            memory("I prefer dark mode.", kind: .preference),
            memory("Rent is due on the first.", kind: .recurringCommitment),
            memory("I don't drink coffee after six.", kind: .preference),
        ]

        let selected = select([commute] + noise, query: "How long is my commute?")
        XCTAssertEqual(selected.map(\.memory.id), [commute.id])
    }

    // MARK: Trust beats similarity

    /// Section 8. To a vector model these two sentences are the same sentence.
    /// The difference is who said it and how sure anyone is — which is exactly
    /// what cosine cannot see and the rest of the score exists to supply.
    func testAnExplicitStatementOutranksAnInferenceSayingTheSameThing() {
        let stated = memory(
            "My commute to work takes thirty minutes.",
            source: .user,
            confidence: 0.95
        )
        let inferred = memory(
            "Commute to work is probably twenty minutes.",
            source: .assistant,
            confidence: 0.5
        )

        let scored = ranker.score(
            [inferred, stated],
            query: MemoryQuery(text: "How long is my commute?", limit: 5, now: now),
            context: context(query: "How long is my commute?", memories: [inferred, stated])
        )

        XCTAssertEqual(scored.first?.memory.id, stated.id)
        XCTAssertGreaterThan(
            scored.first?.sourceTrust ?? 0,
            scored.last?.sourceTrust ?? 1
        )
    }

    /// Section 9's limit. Authority is a strong preference, not an override: a
    /// memory the user stated about something else entirely must not beat a
    /// well-matched inference about the thing they asked about.
    func testExplicitTrustDoesNotDragInAnOffTopicMemory() {
        let statedElsewhere = memory(
            "I prefer Sony cameras.",
            kind: .preference,
            source: .manual,
            salience: 0.9
        )
        let relevantInference = memory(
            "Getting to the office usually takes half an hour.",
            kind: .place,
            source: .assistant
        )

        let selected = select([statedElsewhere, relevantInference], query: "How long is my commute?")
        XCTAssertEqual(selected.map(\.memory.id), [relevantInference.id])
    }

    // MARK: Lifecycle

    func testArchivedAndSupersededMemoriesAreNotRetrieved() {
        var archived = memory("Work is about thirty minutes away.", kind: .place)
        archived.lifecycle = .archived
        var superseded = memory("Work is about twenty minutes away.", kind: .place)
        superseded.lifecycle = .superseded
        let current = memory("Work is about forty minutes away.", kind: .place)

        let selected = select([archived, superseded, current], query: "How long is my commute?")
        XCTAssertEqual(selected.map(\.memory.id), [current.id])
    }

    /// A conflicting memory is penalised rather than excluded, so a caller that
    /// deliberately asks for the history still gets a sensible order — but it is
    /// never the memory a prompt is built from.
    func testAConflictingMemoryIsPushedBelowTheSettledOne() {
        let settled = memory("My commute takes thirty minutes.")
        var disputed = memory("My commute takes forty-five minutes.")
        disputed.lifecycle = .conflicting

        let scored = ranker.score(
            [disputed, settled],
            query: MemoryQuery(
                text: "How long is my commute?",
                lifecycles: MemoryQuery.everyLifecycle,
                limit: 5,
                now: now
            ),
            context: context(query: "How long is my commute?", memories: [disputed, settled])
        )

        XCTAssertEqual(scored.first?.memory.id, settled.id)
        XCTAssertGreaterThan(scored.last?.conflictPenalty ?? 0, 0)
    }

    // MARK: Relations

    /// Section 59. "When should I leave for work?" is answered by two memories,
    /// and the second is easier to find through the first than on its own.
    func testARelatedMemoryCanBeLiftedByTheOneItIsLinkedTo() {
        let commute = memory("Work is about thirty minutes away by car.", kind: .place)
        let preparation = memory("I need about forty-five minutes to get ready.")
        let camera = memory("I like Sony cameras.", kind: .preference)

        let link = MemoryRelation(
            source: commute.id,
            target: preparation.id,
            type: .relatedTo,
            createdAt: now
        )

        let selected = select(
            [commute, preparation, camera],
            query: "When should I leave for work?",
            relations: [link]
        )

        XCTAssertTrue(selected.contains { $0.memory.id == commute.id })
        XCTAssertFalse(selected.contains { $0.memory.id == camera.id })
    }

    /// Section 60. A link is a nudge, never a way past the threshold — otherwise
    /// one relevant memory would drag its whole cluster into the prompt.
    func testALinkDoesNotCarryAnIrrelevantMemoryIntoThePrompt() {
        let commute = memory("Work is about thirty minutes away by car.", kind: .place)
        let camera = memory("I like Sony cameras.", kind: .preference)
        let link = MemoryRelation(
            source: commute.id,
            target: camera.id,
            type: .relatedTo,
            createdAt: now
        )

        let selected = select([commute, camera], query: "How long is my commute?", relations: [link])
        XCTAssertEqual(selected.map(\.memory.id), [commute.id])
    }

    // MARK: Bounds

    func testTheSelectionRespectsTheCountLimit() {
        let policy = MemoryRelevancePolicy(maximumMemories: 2)
        let bounded = MemoryRanker(policy: policy)
        let memories = (0..<6).map { index in
            memory("Getting to work takes about \(20 + index) minutes on route \(index).", kind: .place)
        }

        let selected = bounded.select(
            from: memories,
            query: MemoryQuery(text: "How long is my commute?", limit: 10, now: now),
            context: context(query: "How long is my commute?", memories: memories)
        )
        XCTAssertLessThanOrEqual(selected.count, 2)
    }

    func testTheSelectionRespectsTheCharacterBudget() {
        let policy = MemoryRelevancePolicy(characterBudget: 60)
        let bounded = MemoryRanker(policy: policy)
        let memories = (0..<4).map { index in
            memory(
                "Getting to work takes about \(20 + index) minutes when I go by car in the morning.",
                kind: .place
            )
        }

        let selected = bounded.select(
            from: memories,
            query: MemoryQuery(text: "How long is my commute?", limit: 10, now: now),
            context: context(query: "How long is my commute?", memories: memories)
        )
        XCTAssertLessThanOrEqual(selected.reduce(0) { $0 + $1.memory.content.count }, 60)
    }

    // MARK: Determinism

    func testTheSameInputRanksTheSameWayEveryTime() {
        let memories = [
            memory("Work is thirty minutes away by car.", kind: .place),
            memory("I need forty-five minutes to get ready."),
            memory("I like Sony cameras.", kind: .preference),
        ]

        let first = select(memories, query: "When should I leave for work?").map(\.memory.id)
        let second = select(memories.reversed(), query: "When should I leave for work?").map(\.memory.id)

        XCTAssertEqual(first, second)
    }
}
