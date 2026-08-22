import AssistantDomain
import XCTest
@testable import PersonalMemory

/// Forgetting, and everything that must not be forgotten.
final class MemoryAgingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_078_400)
    private let policy = MemoryAgingPolicy.default

    private func memory(
        _ content: String = "Something the assistant noticed once.",
        kind: MemoryKind = .fact,
        source: MemorySource = .assistant,
        salience: Double = 0.2,
        confidence: Double? = 0.5,
        ageDays: Double,
        lastUsedDaysAgo: Double? = nil,
        lifecycle: MemoryLifecycle = .active,
        entityKeys: [String] = [],
        isProtected: Bool = false,
        consolidatedFrom: [MemoryItem.ID] = []
    ) -> MemoryItem {
        MemoryItem(
            kind: kind,
            content: content,
            salience: salience,
            createdAt: now.addingTimeInterval(-TimeSpan.days(ageDays)),
            lastUsedAt: lastUsedDaysAgo.map { now.addingTimeInterval(-TimeSpan.days($0)) },
            source: source,
            confidence: confidence,
            lifecycle: lifecycle,
            entityKeys: entityKeys,
            consolidatedFrom: consolidatedFrom,
            isProtected: isProtected
        )
    }

    private func decide(
        _ memory: MemoryItem,
        protectedEntityKeys: Set<String> = []
    ) -> MemoryLifecycle {
        policy.decide(for: memory, now: now, protectedEntityKeys: protectedEntityKeys).lifecycle
    }

    // MARK: Fading

    /// Section 83. Inferred, low salience, low confidence, old, never used.
    func testAWeakUnusedInferenceFades() {
        XCTAssertEqual(decide(memory(ageDays: 200)), .stale)
    }

    func testAVeryOldWeakInferenceIsArchived() {
        XCTAssertEqual(decide(memory(ageDays: 500)), .archived)
    }

    func testARecentInferenceIsLeftAlone() {
        XCTAssertEqual(decide(memory(ageDays: 20)), .active)
    }

    /// A guess the app is confident about, or one that clearly matters, is not
    /// what aging is for — section 46 targets weak inferred facts.
    func testASalientInferenceSurvives() {
        XCTAssertEqual(decide(memory(salience: 0.9, confidence: 0.95, ageDays: 500)), .active)
    }

    // MARK: Protection

    /// Section 84. Explicit, confident, salient, old — and untouched.
    func testAnExplicitMemoryIsNotArchivedByAge() {
        let stated = memory(
            "Important reminders should repeat until I have actually done them.",
            kind: .preference,
            source: .user,
            salience: 0.9,
            confidence: 0.95,
            ageDays: 900
        )
        XCTAssertEqual(decide(stated), .active)
    }

    /// Even a low-value explicit memory only fades, and only after years. It is
    /// never archived by age: the user said it, and the app's job is not to
    /// decide they did not mean it.
    func testALowValueExplicitMemoryFadesButIsNeverArchived() {
        let trivial = memory(
            "I once mentioned liking a particular brand of pen.",
            source: .user,
            salience: 0.1,
            confidence: 0.95,
            ageDays: 2_000
        )
        XCTAssertEqual(decide(trivial), .stale)
    }

    /// Section 99 and 41. An edit is the strongest statement of interest there
    /// is, and maintenance leaves it alone from then on.
    func testAnEditedMemoryIsProtectedFromAging() {
        XCTAssertEqual(decide(memory(ageDays: 5_000, isProtected: true)), .active)
    }

    /// Section 85. A memory behind something the user still does is
    /// load-bearing however old it is.
    func testAMemorySupportingAnActiveRoutineIsProtected() {
        let commute = memory(
            "Work is about thirty minutes away.",
            kind: .place,
            ageDays: 900,
            entityKeys: ["place:work"]
        )
        XCTAssertEqual(decide(commute), .archived)
        XCTAssertEqual(decide(commute, protectedEntityKeys: ["place:work"]), .active)
    }

    /// A consolidated fact is the surviving summary of several statements.
    /// Fading it would fade all of them at once.
    func testAConsolidatedFactIsProtected() {
        let consolidated = memory(
            "Work commute usually takes about 30 minutes.",
            ageDays: 900,
            consolidatedFrom: [MemoryItem.ID(), MemoryItem.ID()]
        )
        XCTAssertEqual(decide(consolidated), .active)
    }

    // MARK: Usage

    /// Section 47. Usage buys time — bounded, so a memory cannot refresh its own
    /// lease every time it surfaces and survive forever on one early guess.
    func testRecentUseDelaysFadingButDoesNotPreventIt() {
        let usedRecently = memory(ageDays: 150, lastUsedDaysAgo: 1)
        XCTAssertEqual(decide(usedRecently), .active)

        // The same memory much later, still used yesterday. The credit is
        // capped, so it fades regardless.
        let ancientButUsed = memory(ageDays: 600, lastUsedDaysAgo: 1)
        XCTAssertEqual(decide(ancientButUsed), .archived)
    }

    /// Section 45. Stale is a step, not a verdict — the memory can come back.
    func testAStaleMemoryReturnsToActiveWhenItIsYoungEnoughAgain() {
        let revived = memory(ageDays: 130, lastUsedDaysAgo: 5, lifecycle: .stale)
        XCTAssertEqual(decide(revived), .active)
    }

    // MARK: What aging does not own

    /// Superseded and conflicting are conclusions about truth, and time does not
    /// overturn them. Archiving a superseded memory would also lose the history
    /// the Memory screen shows.
    func testAgingDoesNotTouchSupersededOrConflictingMemories() {
        XCTAssertEqual(decide(memory(ageDays: 5_000, lifecycle: .superseded)), .superseded)
        XCTAssertEqual(decide(memory(ageDays: 5_000, lifecycle: .conflicting)), .conflicting)
    }

    /// Section 45 again: nothing here deletes. The worst outcome is `archived`,
    /// which is visible, restorable and still in the store.
    func testNothingAgesIntoDeletion() {
        for days in stride(from: 0.0, through: 4_000, by: 250) {
            let decision = policy.decide(for: memory(ageDays: days), now: now)
            XCTAssertTrue(
                [.active, .stale, .archived].contains(decision.lifecycle),
                "aging produced \(decision.lifecycle.rawValue) at \(days) days"
            )
        }
    }

    // MARK: Idempotency

    /// Section 36's counterpart for aging: it is a pure function of the memory
    /// and the clock, so a second pass reaches the same answer and writes
    /// nothing.
    func testRunningTwiceReachesTheSameConclusion() {
        var subject = memory(ageDays: 200)
        let first = policy.decide(for: subject, now: now)
        subject.lifecycle = first.lifecycle
        let second = policy.decide(for: subject, now: now)

        XCTAssertEqual(first.lifecycle, second.lifecycle)
        XCTAssertFalse(second.changesAnything)
    }
}
