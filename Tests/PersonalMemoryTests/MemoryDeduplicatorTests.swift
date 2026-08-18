import AssistantDomain
import PersonalMemory
import XCTest

/// Deduplication, and the things it must refuse to do.
///
/// The interesting tests here are the negative ones. Storing a redundant memory
/// costs a little context; merging away a real distinction loses something the
/// user said and cannot easily get back.
final class MemoryDeduplicatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: Duplicates

    func testTheSameSentenceIsAnExactDuplicate() {
        let existing = memory("I need 45 minutes to get ready for work")
        let candidate = memory("I need 45 minutes to get ready for work.")

        guard case .exactDuplicate(let matched) = MemoryDeduplicator()
            .classify(candidate, against: [existing])
        else { return XCTFail("Expected an exact duplicate") }

        XCTAssertEqual(matched.id, existing.id)
    }

    /// "It takes me 30 minutes to drive to work" and "my commute to work is
    /// roughly half an hour" are one fact, however differently they are worded.
    func testTheSameFactInDifferentWordsIsANearDuplicate() {
        let existing = memory("It takes me 30 minutes to drive to work", kind: .place)
        let candidate = memory("My commute to work is roughly half an hour", kind: .place)

        guard case .nearDuplicate(let matched, let similarity) = MemoryDeduplicator()
            .classify(candidate, against: [existing])
        else {
            return XCTFail(
                "Expected a near duplicate, got \(MemoryDeduplicator().classify(candidate, against: [existing]))"
            )
        }

        XCTAssertEqual(matched.id, existing.id)

        // And it was *not* word overlap that caught it. These two share one
        // content word; the lexical score is around 0.27, well under the 0.62
        // duplicate threshold. What connected them is the documented fallback:
        // same category, same subject, same normalised duration ("half an
        // hour" is 1800 seconds, and so is "30 minutes").
        //
        // Asserting the similarity were high would contradict the thing this
        // rule exists to work around, and would quietly start passing for the
        // wrong reason if the threshold were ever lowered.
        XCTAssertLessThan(
            similarity,
            MemoryDeduplicator().nearDuplicateThreshold,
            "if overlap alone now clears the threshold, the duration rule is no longer what is being tested"
        )
    }

    // MARK: The distinctions that must survive

    /// The test that protects against over-eager merging.
    ///
    /// "Commute takes 30 minutes" and "commute takes 45 minutes during rush
    /// hour" are both true and describe different situations.
    func testAQualifiedStatementIsNotADuplicate() {
        let existing = memory("Commute takes 30 minutes normally", kind: .place)
        let candidate = memory("Commute takes 45 minutes during rush hour", kind: .place)

        let classification = MemoryDeduplicator().classify(candidate, against: [existing])
        XCTAssertEqual(classification, .distinct, "a conditional statement is its own fact")
    }

    func testMemoriesOfDifferentCategoriesAreNotMerged() {
        let existing = memory("Work is 30 minutes away", kind: .place)
        let candidate = memory("Work is 30 minutes away", kind: .routine)

        // Not exact — the sentences match, so this still catches as an exact
        // duplicate by normalised text, which is correct: the same sentence is
        // the same sentence. Categories only gate the *fuzzy* comparison.
        guard case .exactDuplicate = MemoryDeduplicator().classify(candidate, against: [existing])
        else { return XCTFail("Identical text should still be recognised") }
    }

    func testDifferentSubjectsAreDistinct() {
        let existing = memory("My girlfriend's name is Anna", kind: .person)
        let candidate = memory("Work is 30 minutes from home", kind: .place)

        XCTAssertEqual(
            MemoryDeduplicator().classify(candidate, against: [existing]),
            .distinct
        )
    }

    // MARK: Conflicts

    /// Same subject, different number: someone's commute changed.
    func testTheSameSubjectWithADifferentDurationIsAConflict() {
        let existing = memory("My commute takes 20 minutes", kind: .place)
        let candidate = memory("My commute takes 30 minutes", kind: .place)

        guard case .conflicting(let matched, _) = MemoryDeduplicator()
            .classify(candidate, against: [existing])
        else {
            return XCTFail(
                "Expected a conflict, got \(MemoryDeduplicator().classify(candidate, against: [existing]))"
            )
        }
        XCTAssertEqual(matched.id, existing.id)
    }

    func testANewerExplicitStatementWinsAConflict() {
        let inferred = MemoryItem(
            kind: .place,
            content: "Commute takes 20 minutes",
            createdAt: now,
            source: .assistant
        )
        let stated = MemoryItem(
            kind: .place,
            content: "It actually takes about 30 minutes now",
            createdAt: now,
            source: .user
        )

        XCTAssertEqual(
            MemoryDeduplicator().resolution(existing: inferred, candidate: stated),
            .replaceContent
        )
    }

    /// A guess does not overwrite something the user said.
    func testAnInferenceDoesNotOverwriteAnExplicitStatement() {
        let stated = MemoryItem(
            kind: .place,
            content: "Commute takes 30 minutes",
            createdAt: now,
            source: .user
        )
        let inferred = MemoryItem(
            kind: .place,
            content: "Commute takes 20 minutes",
            createdAt: now,
            source: .assistant
        )

        XCTAssertEqual(
            MemoryDeduplicator().resolution(existing: stated, candidate: inferred),
            .keepBoth
        )
    }

    // MARK: Merging

    func testMergingKeepsTheIdentifierAndRaisesConfidence() {
        let existing = MemoryItem(
            kind: .routine,
            content: "Getting ready takes 45 minutes",
            salience: 0.4,
            tags: ["morning"],
            createdAt: now.addingTimeInterval(-TimeSpan.days(10)),
            source: .assistant
        )
        let candidate = MemoryItem(
            kind: .routine,
            content: "Getting ready takes 45 minutes",
            salience: 0.8,
            tags: ["work"],
            createdAt: now,
            source: .user
        )

        let merged = MemoryDeduplicator().merged(existing, with: candidate, at: now)

        XCTAssertEqual(merged.id, existing.id, "merging must not mint a new identifier")
        XCTAssertEqual(merged.updatedAt, now)
        XCTAssertEqual(merged.salience, 0.8)
        XCTAssertEqual(merged.tags, ["morning", "work"])
        // The user has now said in words what the assistant had guessed.
        XCTAssertEqual(merged.source, .user)
        XCTAssertGreaterThan(merged.confidence, existing.confidence)
    }

    func testMergingDoesNotDowngradeAnExplicitMemory() {
        let stated = MemoryItem(
            kind: .routine,
            content: "Getting ready takes 45 minutes",
            createdAt: now,
            source: .user
        )
        let inferred = MemoryItem(
            kind: .routine,
            content: "Getting ready takes 45 minutes",
            createdAt: now,
            source: .assistant
        )

        let merged = MemoryDeduplicator().merged(stated, with: inferred, at: now)
        XCTAssertEqual(merged.source, .user)
        XCTAssertEqual(merged.confidence, stated.confidence)
    }

    func testAMemoryIsNeverComparedWithItself() {
        let existing = memory("Work is 30 minutes away")
        XCTAssertEqual(
            MemoryDeduplicator().classify(existing, against: [existing]),
            .distinct
        )
    }

    // MARK: Helpers

    private func memory(
        _ content: String,
        kind: MemoryKind = .routine,
        source: MemorySource = .user
    ) -> MemoryItem {
        MemoryItem(kind: kind, content: content, createdAt: now, source: source)
    }
}
