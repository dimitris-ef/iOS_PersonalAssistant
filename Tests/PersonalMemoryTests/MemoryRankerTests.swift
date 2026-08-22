import AssistantDomain
import PersonalMemory
import XCTest

/// What the assistant recalls, and what it leaves alone.
///
/// No model is involved in any of this, which is the point: retrieval has to be
/// deterministic, offline and identical whichever provider is selected.
final class MemoryRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: The milestone's own example

    /// "I work tomorrow at 4 PM. When should I start getting ready and leave?"
    func testASchedulingQuestionRecallsTheRoutineAndThePlace() {
        let library = MemoryLibrary(now: now)
        let selected = MemoryRanker().select(
            from: library.all,
            query: query("I work tomorrow at 4 PM. When should I start getting ready and leave?")
        )

        let contents = selected.map(\.memory.content)
        XCTAssertTrue(contents.contains(library.gettingReady.content), "\(contents)")
        XCTAssertTrue(contents.contains(library.commute.content), "\(contents)")

        // The exclusions matter more than the inclusions. These are the
        // memories that make an assistant feel like it is rifling through your
        // things.
        XCTAssertFalse(contents.contains(library.camera.content))
        XCTAssertFalse(contents.contains(library.girlfriend.content))
        XCTAssertFalse(contents.contains(library.groceries.content))
    }

    func testTheWorkMemoriesOutrankEverythingElse() {
        let library = MemoryLibrary(now: now)
        let scored = MemoryRanker().score(
            library.all,
            query: query("When should I leave for work?")
        )

        let top = scored.prefix(2).map(\.memory.content)
        XCTAssertTrue(top.contains(library.commute.content), "\(scored.map(\.memory.content))")

        let cameraRank = scored.firstIndex { $0.memory.id == library.camera.id } ?? .max
        let commuteRank = scored.firstIndex { $0.memory.id == library.commute.id } ?? .max
        XCTAssertLessThan(commuteRank, cameraRank)
    }

    /// "Remind me to pay the electricity bill tomorrow."
    func testAReminderRequestFavoursTheReminderPreference() {
        let library = MemoryLibrary(now: now)
        let scored = MemoryRanker().score(
            library.all,
            query: query("Remind me to pay the electricity bill tomorrow")
        )

        let reminderRank = scored.firstIndex { $0.memory.id == library.reminderPreference.id } ?? .max
        let cameraRank = scored.firstIndex { $0.memory.id == library.camera.id } ?? .max
        let girlfriendRank = scored.firstIndex { $0.memory.id == library.girlfriend.id } ?? .max

        XCTAssertLessThan(reminderRank, cameraRank)
        XCTAssertLessThan(reminderRank, girlfriendRank)
    }

    // MARK: Selection, not just ordering

    func testNothingRelevantMeansNothingSelected() {
        let library = MemoryLibrary(now: now)
        let selected = MemoryRanker().select(
            from: library.all,
            query: query("What is the capital of Peru?")
        )

        // The quota is not a target. Five slots do not mean five memories.
        XCTAssertTrue(
            selected.isEmpty,
            "unrelated memories were injected anyway: \(selected.map(\.memory.content))"
        )
    }

    /// The regression behind `minimumRelevance`.
    ///
    /// A weighted sum lets the supporting factors stand in for relevance: a
    /// memory the user typed themselves, marked important, in the category the
    /// question is about, collects salience, confidence and affinity points
    /// whether or not it has anything to do with what was asked — and that is
    /// enough to clear a score threshold on its own. Relevance has to be able
    /// to veto, or "the others only reorder things already on topic" is a
    /// description of an intention rather than of the code.
    func testAPerfectMemoryOnTheWrongSubjectIsStillNotSelected() throws {
        // Maximum salience, maximum confidence, freshly written, and in the
        // exact category a scheduling question prefers.
        let irrelevant = MemoryItem(
            kind: .routine,
            content: "I always rinse the cafetière before bed",
            salience: 1.0,
            createdAt: now,
            source: .manual
        )
        let request = query("when do I leave for work")

        let scored = try XCTUnwrap(MemoryRanker().score([irrelevant], query: request).first)
        XCTAssertEqual(scored.lexical, 0, "it shares no content word with the request")
        // The weighted score is comfortably above the threshold on the strength
        // of everything else — which is precisely why the threshold alone
        // cannot be trusted with this.
        XCTAssertGreaterThan(scored.finalScore, MemoryRelevancePolicy.default.minimumScore)

        XCTAssertTrue(MemoryRanker().select(from: [irrelevant], query: request).isEmpty)
    }

    /// The gate must not take relevant memories down with it.
    ///
    /// Selection walks candidates in final-score order, and an irrelevant
    /// memory can outrank a weakly relevant one. Stopping at the first rejected
    /// candidate would silently drop the memory that actually answers the
    /// question.
    func testAnIrrelevantMemoryOutrankingARelevantOneDoesNotBlockIt() {
        let loud = MemoryItem(
            kind: .routine,
            content: "I always rinse the cafetière before bed",
            salience: 1.0,
            createdAt: now,
            source: .manual
        )
        // Weakly relevant on every other axis: unimportant, old, inferred, and
        // in a category the request does not favour. It shares one word with
        // the question, and that word is the whole point of asking.
        let quiet = MemoryItem(
            kind: .fact,
            content: "Parking near the office costs four pounds an hour",
            salience: 0.1,
            createdAt: now.addingTimeInterval(-TimeSpan.days(400)),
            source: .assistant
        )
        let request = query("should I book parking or find something on the street tomorrow")

        let ranked = MemoryRanker().score([loud, quiet], query: request)
        XCTAssertEqual(ranked.map(\.memory.id), [loud.id, quiet.id], "the premise: loud ranks first")

        let selected = MemoryRanker().select(from: [loud, quiet], query: request)
        XCTAssertEqual(selected.map(\.memory.id), [quiet.id])
    }

    /// A disagreement the write path could not settle must not reach a model.
    ///
    /// `MemoryService` deliberately keeps both when a guess contradicts
    /// something the user said, so the user can see it and delete the wrong
    /// one. Sending a model both halves of that would just move the decision
    /// somewhere nobody can inspect it.
    func testTwoContradictoryMemoriesAreNotInjectedTogether() {
        let stated = MemoryItem(
            kind: .place,
            content: "My commute takes 30 minutes",
            salience: 0.7,
            createdAt: now,
            source: .user
        )
        let guessed = MemoryItem(
            kind: .place,
            content: "My commute takes 50 minutes",
            salience: 0.7,
            createdAt: now,
            source: .assistant
        )

        let selected = MemoryRanker().select(
            from: [guessed, stated],
            query: query("how long is my commute")
        )

        XCTAssertEqual(selected.count, 1)
        // The one the user actually said: explicit sources carry more
        // confidence, confidence feeds the score, and the score decides.
        XCTAssertEqual(selected.first?.memory.id, stated.id)
    }

    /// Suppression is for contradictions only.
    func testTwoMemoriesThatMerelyAgreeAreBothKept() {
        let selected = MemoryRanker().select(
            from: [
                memory("I leave for work at eight", kind: .routine),
                memory("I cycle to work", kind: .routine),
            ],
            query: query("when do I leave for work")
        )

        XCTAssertEqual(selected.count, 2)
    }

    func testSelectionNeverExceedsTheConfiguredMaximum() {
        let policy = MemoryRelevancePolicy(maximumMemories: 3)
        // Eight memories that all genuinely mention work.
        let candidates = (0..<8).map { index in
            MemoryItem(
                kind: .routine,
                content: "Work routine number \(index): I leave for work early",
                salience: 0.8,
                createdAt: now,
                source: .user
            )
        }

        let selected = MemoryRanker(policy: policy).select(
            from: candidates,
            query: query("when do I leave for work")
        )

        XCTAssertLessThanOrEqual(selected.count, 3)
        XCTAssertEqual(selected.count, 3)
        // And the ones kept are the best ones.
        let scores = selected.map(\.finalScore)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    func testTheQueryLimitCanTightenButNotLoosenTheMaximum() {
        let policy = MemoryRelevancePolicy(maximumMemories: 5)
        let library = MemoryLibrary(now: now)

        let tightened = MemoryRanker(policy: policy).select(
            from: library.all,
            query: MemoryQuery(text: "leaving for work", limit: 1, now: now)
        )
        XCTAssertLessThanOrEqual(tightened.count, 1)

        let loosened = MemoryRanker(policy: policy).select(
            from: library.all,
            query: MemoryQuery(text: "leaving for work", limit: 50, now: now)
        )
        XCTAssertLessThanOrEqual(loosened.count, 5)
    }

    /// One long memory must not swallow the whole allowance.
    func testTheCharacterBudgetIsRespected() {
        let policy = MemoryRelevancePolicy(maximumMemories: 5, characterBudget: 120)
        let long = MemoryItem(
            kind: .routine,
            content: String(repeating: "work ", count: 60),
            salience: 0.9,
            createdAt: now,
            source: .user
        )
        let short = MemoryItem(
            kind: .routine,
            content: "I leave for work at 8",
            salience: 0.9,
            createdAt: now,
            source: .user
        )

        let selected = MemoryRanker(policy: policy).select(
            from: [long, short],
            query: query("when do I leave for work")
        )

        let total = selected.reduce(0) { $0 + $1.memory.content.count }
        XCTAssertLessThanOrEqual(total, 120)
        // The oversized one is skipped rather than blocking the one that fits.
        XCTAssertTrue(selected.contains { $0.memory.id == short.id })
    }

    // MARK: Individual signals

    func testSalienceSeparatesEquallyRelevantMemories() {
        let important = memory("I leave for work at eight", salience: 0.9)
        let incidental = memory("I leave for work at eight", salience: 0.1)

        let scored = MemoryRanker().score(
            [incidental, important],
            query: query("when do I leave for work")
        )
        XCTAssertEqual(scored.first?.memory.id, important.id)
    }

    /// An explicit statement beats an equivalent guess.
    func testConfidenceSeparatesEquallyRelevantMemories() {
        let stated = MemoryItem(
            kind: .place,
            content: "Work is 30 minutes from home",
            salience: 0.5,
            createdAt: now,
            source: .user
        )
        let guessed = MemoryItem(
            kind: .place,
            content: "Work is 30 minutes from home",
            salience: 0.5,
            createdAt: now,
            source: .assistant
        )

        let scored = MemoryRanker().score(
            [guessed, stated],
            query: query("how far is work")
        )

        XCTAssertEqual(scored.first?.memory.id, stated.id)
        XCTAssertGreaterThan(stated.confidence, guessed.confidence)
    }

    func testRecencySeparatesEquallyRelevantMemories() {
        let older = memory("I leave for work at eight", createdAt: now.addingTimeInterval(-TimeSpan.days(300)))
        let newer = memory("I leave for work at eight", createdAt: now.addingTimeInterval(-TimeSpan.days(1)))

        let scored = MemoryRanker().score(
            [older, newer],
            query: query("when do I leave for work")
        )
        XCTAssertEqual(scored.first?.memory.id, newer.id)
    }

    /// The rule that keeps an assistant useful as it gets older: a year-old
    /// commute time beats yesterday's note about shampoo.
    func testAnOldRelevantMemoryBeatsANewIrrelevantOne() {
        let oldAndUseful = MemoryItem(
            kind: .place,
            content: "My work commute normally takes 30 minutes",
            salience: 0.7,
            createdAt: now.addingTimeInterval(-TimeSpan.days(400)),
            source: .user
        )
        let newAndUseless = MemoryItem(
            kind: .fact,
            content: "I bought shampoo",
            salience: 0.2,
            createdAt: now.addingTimeInterval(-TimeSpan.days(1)),
            source: .user
        )

        let scored = MemoryRanker().score(
            [newAndUseless, oldAndUseful],
            query: query("how long is my commute to work")
        )
        XCTAssertEqual(scored.first?.memory.id, oldAndUseful.id)
    }

    /// Category is a thumb on the scale, not a gate.
    func testCategoryInfluencesRankingWithoutDecidingIt() {
        let routine = MemoryItem(
            kind: .routine,
            content: "Getting ready takes forty five minutes",
            salience: 0.5,
            createdAt: now,
            source: .user
        )
        let preference = MemoryItem(
            kind: .preference,
            content: "Getting ready takes forty five minutes",
            salience: 0.5,
            createdAt: now,
            source: .user
        )

        let scored = MemoryRanker().score(
            [preference, routine],
            query: query("how long before I leave should I start getting ready")
        )

        // Same words, same salience, same confidence: only the category
        // differs, and a scheduling question prefers the routine.
        XCTAssertEqual(scored.first?.memory.id, routine.id)
        // But the preference is still ranked, not filtered out — it matches.
        XCTAssertEqual(scored.count, 2)
        XCTAssertGreaterThan(scored[1].lexical, 0)
    }

    // MARK: Determinism

    func testScoringIsStableAcrossRuns() {
        let library = MemoryLibrary(now: now)
        let ranker = MemoryRanker()
        let first = ranker.score(library.all, query: query("when do I leave for work"))
        let second = ranker.score(library.all.reversed(), query: query("when do I leave for work"))
        XCTAssertEqual(first.map(\.memory.id), second.map(\.memory.id))
    }

    func testAnEmptyQueryFallsBackToStandingSignals() {
        let library = MemoryLibrary(now: now)
        let scored = MemoryRanker().score(library.all, query: MemoryQuery(text: "", now: now))
        XCTAssertEqual(scored.count, library.all.count)
        XCTAssertEqual(scored.map(\.lexical).max(), 0.5)
    }

    func testEmptyMemoriesAreIgnored() {
        let blank = MemoryItem(kind: .fact, content: "   ", createdAt: now, source: .user)
        let scored = MemoryRanker().score([blank], query: query("anything"))
        XCTAssertTrue(scored.isEmpty)
    }

    // MARK: Helpers

    private func query(_ text: String) -> MemoryQuery {
        MemoryQuery(text: text, limit: 10, now: now)
    }

    private func memory(
        _ content: String,
        kind: MemoryKind = .routine,
        salience: Double = 0.5,
        createdAt: Date? = nil
    ) -> MemoryItem {
        MemoryItem(
            kind: kind,
            content: content,
            salience: salience,
            createdAt: createdAt ?? now,
            source: .user
        )
    }
}

/// The memory set from the milestone's behavioural example.
struct MemoryLibrary {
    let gettingReady: MemoryItem
    let commute: MemoryItem
    let reminderPreference: MemoryItem
    let girlfriend: MemoryItem
    let camera: MemoryItem
    let groceries: MemoryItem

    var all: [MemoryItem] {
        [gettingReady, commute, reminderPreference, girlfriend, camera, groceries]
    }

    init(now: Date) {
        gettingReady = MemoryItem(
            kind: .routine,
            content: "I usually need 45 minutes to get ready for work",
            salience: 0.8,
            createdAt: now.addingTimeInterval(-TimeSpan.days(30)),
            source: .user
        )
        commute = MemoryItem(
            kind: .place,
            content: "Work is normally 30 minutes from home",
            salience: 0.8,
            createdAt: now.addingTimeInterval(-TimeSpan.days(60)),
            source: .user
        )
        reminderPreference = MemoryItem(
            kind: .preference,
            content: "I prefer important reminders to repeat until I confirm completion",
            salience: 0.7,
            createdAt: now.addingTimeInterval(-TimeSpan.days(10)),
            source: .user
        )
        girlfriend = MemoryItem(
            kind: .person,
            content: "My girlfriend's name is Anna",
            salience: 0.6,
            createdAt: now.addingTimeInterval(-TimeSpan.days(90)),
            source: .user
        )
        camera = MemoryItem(
            kind: .preference,
            content: "I like Sony cameras",
            salience: 0.3,
            createdAt: now.addingTimeInterval(-TimeSpan.days(5)),
            source: .user
        )
        groceries = MemoryItem(
            kind: .recurringCommitment,
            content: "I normally buy groceries on Saturday",
            salience: 0.5,
            createdAt: now.addingTimeInterval(-TimeSpan.days(20)),
            source: .user
        )
    }
}
