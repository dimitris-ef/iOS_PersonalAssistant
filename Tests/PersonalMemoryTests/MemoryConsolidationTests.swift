import AssistantDomain
import XCTest
@testable import PersonalMemory

/// Collapsing repeated facts, and the four kinds of pair that must never be
/// collapsed.
final class MemoryConsolidationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_078_400)
    private let consolidator = MemoryConsolidator()

    private func memory(
        _ content: String,
        kind: MemoryKind = .routine,
        source: MemorySource = .user,
        confidence: Double? = nil,
        ageDays: Double = 30
    ) -> MemoryItem {
        MemoryItem(
            kind: kind,
            content: content,
            createdAt: now.addingTimeInterval(-TimeSpan.days(ageDays)),
            source: source,
            confidence: confidence,
            entityKeys: MemoryEntityExtractor.keys(for: content, kind: kind)
        )
    }

    private func vectors(_ memories: [MemoryItem]) -> [MemoryItem.ID: SemanticVector] {
        Dictionary(
            memories.map { ($0.id, LexiconSemanticEncoder.vector(for: $0.content)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func plans(_ memories: [MemoryItem]) -> [MemoryConsolidation] {
        consolidator.consolidations(among: memories, vectors: vectors(memories), now: now)
    }

    // MARK: The example

    /// Section 27 and 119. Three rows, three entries competing for the same
    /// prompt slot, one fact.
    func testThreeStatementsOfOneFactBecomeOne() {
        let memories = [
            memory("I take about 30 minutes to get to work.", ageDays: 90),
            memory("My commute is usually half an hour.", ageDays: 60),
            memory("It normally takes around 30 minutes to drive to work.", ageDays: 30),
        ]

        let results = plans(memories)
        XCTAssertEqual(results.count, 1)

        let plan = try? XCTUnwrap(results.first)
        XCTAssertEqual(plan?.superseded.count, 3)
        XCTAssertEqual(plan?.consolidated.consolidatedFrom.count, 3)
        // The surviving wording is one the user actually used, never a
        // generated sentence.
        XCTAssertTrue(memories.map(\.content).contains(plan?.consolidated.content ?? ""))
    }

    /// Section 30. The evidence is superseded, not destroyed.
    func testSourceMemoriesAreSupersededRatherThanDeleted() {
        let memories = [
            memory("I take about 30 minutes to get to work."),
            memory("My commute is usually half an hour."),
        ]

        let plan = plans(memories).first
        XCTAssertEqual(plan?.superseded.map(\.lifecycle), [.superseded, .superseded])
        XCTAssertEqual(Set(plan?.superseded.map(\.id) ?? []), Set(memories.map(\.id)))
    }

    /// Section 29. Provenance, both ways: the consolidated fact knows what it
    /// came from and each source knows what it supports.
    func testProvenanceIsRecordedInBothDirections() {
        let memories = [
            memory("I take about 30 minutes to get to work."),
            memory("My commute is usually half an hour."),
        ]

        let plan = plans(memories).first
        let supports = plan?.relations.filter { $0.type == .supports } ?? []
        let derived = plan?.relations.filter { $0.type == .derivedFrom } ?? []

        XCTAssertEqual(supports.count, 2)
        XCTAssertEqual(derived.count, 2)
        XCTAssertTrue(supports.allSatisfy { $0.target == plan?.consolidated.id })
        XCTAssertTrue(derived.allSatisfy { $0.source == plan?.consolidated.id })
    }

    // MARK: The four pairs that must survive

    /// Section 32. Both statements are true, about different situations.
    func testAConditionalStatementIsNotMergedWithTheGeneralOne() {
        let memories = [
            memory("Commute takes 30 minutes normally."),
            memory("Commute takes 45 minutes during rush hour."),
        ]
        XCTAssertTrue(plans(memories).isEmpty)
    }

    /// Section 56. The number is the entire distinction, and it is the part a
    /// bag of concepts throws away first.
    func testTwoDifferentDurationsAreNotMerged() {
        let memories = [
            memory("Normal commute is 30 minutes."),
            memory("Rush-hour commute is 45 minutes."),
        ]
        XCTAssertTrue(plans(memories).isEmpty)
    }

    /// Section 57. Embeddings put these almost on top of each other. Polarity is
    /// checked before similarity is consulted at all.
    func testOppositePreferencesAreNotMerged() {
        let memories = [
            memory("I like coffee.", kind: .preference),
            memory("I don't like coffee.", kind: .preference),
        ]
        XCTAssertTrue(plans(memories).isEmpty)
    }

    /// Section 31's second example: a broad preference and a conditional
    /// behaviour are different claims.
    func testABroadPreferenceIsNotMergedWithAConditionalOne() {
        let memories = [
            memory("I like coffee.", kind: .preference),
            memory("I avoid coffee after 6 PM.", kind: .preference),
        ]
        XCTAssertTrue(plans(memories).isEmpty)
    }

    func testMemoriesAboutDifferentSubjectsAreNotMerged() {
        let memories = [
            memory("Getting to work takes 30 minutes.", kind: .place),
            memory("Getting to the gym takes 30 minutes.", kind: .place),
        ]
        XCTAssertTrue(plans(memories).isEmpty)
    }

    func testMemoriesOfDifferentCategoriesAreNotMerged() {
        let memories = [
            memory("Work is half an hour away.", kind: .place),
            memory("Work is half an hour away.", kind: .routine),
        ]
        XCTAssertTrue(plans(memories).isEmpty)
    }

    // MARK: Idempotency and loops

    /// Section 79 and 100. After one pass the sources are superseded and the
    /// result is consolidated, so there is nothing a second pass can see. The
    /// runaway A+B→C, C+A→D cannot be expressed.
    func testASecondPassOverTheResultProducesNothing() {
        let memories = [
            memory("I take about 30 minutes to get to work."),
            memory("My commute is usually half an hour."),
            memory("It normally takes around 30 minutes to drive to work."),
        ]

        let first = plans(memories)
        XCTAssertEqual(first.count, 1)

        let afterFirstPass = (first[0].superseded) + [first[0].consolidated]
        XCTAssertTrue(plans(afterFirstPass).isEmpty)
    }

    /// And the identity is derived from the sources, so even re-running against
    /// the *original* active memories produces the same record rather than a
    /// second one.
    func testTheConsolidatedIdentityIsDerivedFromItsSources() {
        let memories = [
            memory("I take about 30 minutes to get to work."),
            memory("My commute is usually half an hour."),
        ]

        XCTAssertEqual(
            plans(memories).first?.consolidated.id,
            plans(memories.reversed()).first?.consolidated.id
        )
    }

    /// Section 99. A memory the user edited is theirs; maintenance does not
    /// rewrite it from the statements it once summarised.
    func testAProtectedMemoryIsLeftAlone() {
        var edited = memory("I take about 30 minutes to get to work.")
        edited.isProtected = true
        let other = memory("My commute is usually half an hour.")

        XCTAssertTrue(plans([edited, other]).isEmpty)
    }

    // MARK: Confidence

    /// Section 36. Repetition corroborates; it does not manufacture certainty,
    /// and a pile of inferences never reaches the standing of one sentence the
    /// user said.
    func testRepeatedInferencesStayBelowAnExplicitStatement() {
        let inferences = (0..<4).map { index in
            memory(
                "Commute to work is about 30 minutes, roughly, seen \(index) times.",
                source: .assistant,
                confidence: 0.6
            )
        }

        let plan = plans(inferences).first
        let consolidatedConfidence = plan?.consolidated.confidence ?? 1

        XCTAssertGreaterThan(consolidatedConfidence, 0.6)
        XCTAssertLessThan(consolidatedConfidence, MemorySource.user.defaultConfidence)
    }

    func testAgreementRaisesConfidenceWithinLimits() {
        let memories = [
            memory("I take about 30 minutes to get to work.", source: .user, confidence: 0.9),
            memory("My commute is usually half an hour.", source: .user, confidence: 0.9),
        ]

        let plan = plans(memories).first
        XCTAssertGreaterThan(plan?.consolidated.confidence ?? 0, 0.9)
        XCTAssertLessThanOrEqual(plan?.consolidated.confidence ?? 0, 1)
    }

    /// The surviving wording prefers what the user said over what the app
    /// worked out, whichever is longer or newer.
    func testTheUsersOwnWordingSurvivesOverAnInference() {
        let stated = memory(
            "My commute to work is usually about 30 minutes, give or take.",
            source: .user
        )
        let inferred = memory("Commute to work: 30 minutes.", source: .assistant)

        let plan = plans([inferred, stated]).first
        XCTAssertEqual(plan?.consolidated.content, stated.content)
        XCTAssertEqual(plan?.consolidated.source, .user)
    }
}
