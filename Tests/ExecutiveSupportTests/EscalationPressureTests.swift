import AssistantDomain
import ExecutiveSupport
import XCTest

/// How hard the assistant pushes, and the two bounds on it.
///
/// Part 8 widened escalation to read dismissals and misses as well as snoozes.
/// These tests pin the arithmetic, because the first attempt at it summed all
/// four counters and quietly collapsed the priority ladder — one dismissal
/// registered as two failed attempts, which halved the interval twice and put
/// `.high` and `.critical` on the same ten-minute floor.
final class EscalationPressureTests: XCTestCase {
    private let timing = FollowUpTiming.default
    private let now = Date(timeIntervalSince1970: 1_781_078_400)

    private func task(
        followUps: Int = 0,
        snoozes: Int = 0,
        dismissals: Int = 0,
        misses: Int = 0
    ) -> TaskItem {
        TaskItem(
            title: "Pay the electricity bill",
            followUpCount: followUps,
            snoozeCount: snoozes,
            dismissalCount: dismissals,
            missCount: misses,
            createdAt: now
        )
    }

    // MARK: Pressure

    func testAFreshTaskCarriesNoPressure() {
        XCTAssertEqual(timing.pressure(for: task()), 0)
    }

    /// `followUpCount` already counts the attempt a dismissal spent. Counting
    /// the dismissal again would make one swipe look like two.
    func testOneDismissalIsOneAttemptNotTwo() {
        XCTAssertEqual(timing.pressure(for: task(followUps: 1, dismissals: 1)), 1)
    }

    /// The same for silence: a miss spends a follow-up, and `missCount`
    /// classifies that attempt rather than adding another.
    func testMissesAreNotCountedOnTopOfTheFollowUpsTheySpent() {
        XCTAssertEqual(timing.pressure(for: task(followUps: 3, misses: 3)), 3)
    }

    /// What repetition adds. Three dismissals say something one does not: this
    /// person has now decided not to act, more than once.
    func testRepeatedDismissalsAddPressureBeyondTheFirst() {
        let once = timing.pressure(for: task(followUps: 1, dismissals: 1))
        let thrice = timing.pressure(for: task(followUps: 3, dismissals: 3))
        XCTAssertEqual(once, 1)
        XCTAssertEqual(thrice, 5)
    }

    /// A snooze defers without spending a follow-up, so it is pressure nothing
    /// else has recorded and counts in full.
    func testSnoozesCountInFull() {
        XCTAssertEqual(timing.pressure(for: task(followUps: 1, snoozes: 2)), 3)
    }

    // MARK: The ladder still means something

    /// The regression this file exists for: at every pressure level, a task
    /// that matters more is chased sooner — or at worst equally soon, once both
    /// have hit the floor.
    func testMoreImportantTasksAreNeverChasedLaterThanLessImportantOnes() {
        for attempt in 0...4 {
            let delays = Importance.allCases.map { importance in
                timing.delay(importance: importance, attempt: attempt, deadline: nil, now: now)
            }
            for (earlier, later) in zip(delays, delays.dropFirst()) {
                XCTAssertGreaterThanOrEqual(
                    earlier, later,
                    "at attempt \(attempt) the ladder inverted"
                )
            }
        }

        // And at the first real attempt the ladder is strict, not flattened by
        // the floor — which is the property the double-count destroyed.
        XCTAssertGreaterThan(
            timing.delay(importance: .normal, attempt: 1, deadline: nil, now: now),
            timing.delay(importance: .high, attempt: 1, deadline: nil, now: now)
        )
        XCTAssertGreaterThan(
            timing.delay(importance: .high, attempt: 1, deadline: nil, now: now),
            timing.delay(importance: .critical, attempt: 1, deadline: nil, now: now)
        )
    }

    func testTheIntervalNeverFallsBelowTheFloor() {
        for attempt in 0...20 {
            XCTAssertGreaterThanOrEqual(
                timing.delay(importance: .critical, attempt: attempt, deadline: nil, now: now),
                timing.minimumInterval
            )
        }
    }

    // MARK: Bounds

    /// Adaptive is not the same as unbounded. Without a ceiling, a task ignored
    /// six times reaches the noisiest level in the enum and stays there, which
    /// is how a support tool becomes something people disable.
    func testEscalationSaturatesAtTheCeiling() {
        let quiet = FollowUpTiming(maximumEscalation: .insistent)
        for attempt in 0...10 {
            XCTAssertLessThanOrEqual(
                quiet.escalation(importance: .critical, attempt: attempt, base: .standard),
                .insistent
            )
        }
    }

    func testEscalationRisesWithRepeatedFailureUpToTheCeiling() {
        let first = timing.escalation(importance: .normal, attempt: 0, base: .gentle)
        let later = timing.escalation(importance: .normal, attempt: 2, base: .gentle)
        XCTAssertGreaterThan(later, first)
        XCTAssertLessThanOrEqual(later, timing.maximumEscalation)
    }

    /// The other half of boundedness: escalation controls how loud, this
    /// controls how often. Counted from stages the plan actually scheduled, so
    /// it survives a relaunch — a budget kept in memory would reset exactly
    /// when a storm would otherwise start.
    func testADayHasAnInterventionBudget() {
        var plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(TaskItem.ID()),
                title: "Pay the electricity bill",
                anchor: .unscheduled
            ),
            stages: [],
            createdAt: now,
            generatedBy: "test"
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!

        XCTAssertFalse(timing.hasExhaustedDailyBudget(plan: plan, now: now, calendar: calendar))

        plan.stages = (0..<timing.maximumInterventionsPerDay).map { index in
            ReminderStage(
                kind: .nudge,
                offset: .absolute(now),
                message: "again",
                scheduledFor: now.addingTimeInterval(TimeSpan.minutes(Double(index * 5)))
            )
        }

        XCTAssertTrue(timing.hasExhaustedDailyBudget(plan: plan, now: now, calendar: calendar))
    }
}
