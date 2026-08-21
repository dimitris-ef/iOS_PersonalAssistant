import AssistantDomain
import ExecutiveSupport
import XCTest

/// Generating occurrences, and deciding what to do about the ones that were
/// missed.
final class RoutineSchedulerTests: XCTestCase {
    private let scheduler = RoutineScheduler()

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute)
        )!
    }

    private func routine(
        title: String = "Take medication",
        hour: Int = 9,
        recovery: RoutineRecoveryPolicy = RoutineRecoveryPolicy(),
        isActive: Bool = true,
        steps: [PreparationStep] = []
    ) -> Routine {
        Routine(
            title: title,
            recurrence: RecurrenceRule(
                frequency: .daily,
                timeOfDay: TimeOfDay(hour: hour),
                startDate: date(1)
            ),
            isActive: isActive,
            recovery: recovery,
            preparationSteps: steps,
            createdAt: date(1)
        )
    }

    // MARK: Generation

    func testOccurrencesAreGeneratedInsideTheHorizonAndNoFurther() {
        let routine = routine()
        let created = scheduler.pendingOccurrences(
            for: routine,
            existing: [],
            now: date(10, 8),
            calendar: calendar
        )

        // A two-day horizon from 08:00 on the 10th reaches 08:00 on the 12th,
        // so it covers the 10th and the 11th — not a year of mornings.
        XCTAssertEqual(created.map(\.occurrenceDate), [date(10, 9), date(11, 9)])
    }

    /// Relaunching the app three times before breakfast must produce one
    /// morning medication task, not three.
    func testGeneratingTwiceProducesTheSameOccurrenceRatherThanASecondOne() {
        let routine = routine()
        let now = date(10, 8)

        let first = scheduler.pendingOccurrences(
            for: routine, existing: [], now: now, calendar: calendar
        )
        let second = scheduler.pendingOccurrences(
            for: routine, existing: first, now: now, calendar: calendar
        )

        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
    }

    func testACompletedOccurrenceIsNotRegenerated() {
        let routine = routine()
        let now = date(10, 8)

        var done = scheduler.occurrence(of: routine, at: date(10, 9), now: now)
        done.status = .completed

        let pending = scheduler.pendingOccurrences(
            for: routine, existing: [done], now: now, calendar: calendar
        )
        XCTAssertEqual(pending.map(\.occurrenceDate), [date(11, 9)])
    }

    func testAPausedRoutineGeneratesNothing() {
        let paused = routine(isActive: false)
        XCTAssertTrue(
            scheduler.pendingOccurrences(
                for: paused, existing: [], now: date(10, 8), calendar: calendar
            ).isEmpty
        )
    }

    /// Completing Tuesday's "pack the kit" must not tick Thursday's.
    func testStepsAreCopiedOntoEachOccurrenceRatherThanShared() {
        let template = PreparationStep(
            title: "Pack the kit",
            estimatedDuration: TimeSpan.minutes(5)
        )
        let routine = routine(steps: [template])

        let tuesday = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))
        let thursday = scheduler.occurrence(of: routine, at: date(12, 9), now: date(10, 8))

        XCTAssertEqual(tuesday.preparationSteps.count, 1)
        XCTAssertNotEqual(
            tuesday.preparationSteps[0].id,
            thursday.preparationSteps[0].id
        )
        XCTAssertFalse(tuesday.preparationSteps[0].isCompleted)
    }

    // MARK: Recovery

    func testALateOccurrenceInsideItsWindowIsStillWorthDoing() {
        let routine = routine(recovery: RoutineRecoveryPolicy(window: TimeSpan.hours(4)))
        let occurrence = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))

        let decision = scheduler.recoveryDecision(
            for: occurrence, routine: routine, now: date(10, 11), calendar: calendar
        )
        XCTAssertEqual(decision, .recover(until: date(10, 13)))

        let updated = scheduler.applying(decision, to: occurrence, at: date(10, 11))
        XCTAssertEqual(updated.status, .missed)
        XCTAssertTrue(updated.status.isOutstanding)
    }

    func testAnOccurrencePastItsWindowExpiresRatherThanBeingChasedForever() {
        let routine = routine(recovery: RoutineRecoveryPolicy(window: TimeSpan.hours(4)))
        let occurrence = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))

        let decision = scheduler.recoveryDecision(
            for: occurrence, routine: routine, now: date(10, 16), calendar: calendar
        )
        XCTAssertEqual(decision, .expire)

        let updated = scheduler.applying(decision, to: occurrence, at: date(10, 16))
        XCTAssertEqual(updated.status, .expired)
        // Expired is not done. Nothing may claim otherwise.
        XCTAssertNil(updated.completedAt)
        XCTAssertFalse(updated.status.isSuccess)
    }

    /// The bins on Thursday night are still worth taking out on Friday morning,
    /// which twelve hours of raw window would not reach from 8 PM.
    func testAnEveningRoutineCanStayRecoverableIntoTheNextDay() {
        let routine = routine(
            hour: 20,
            recovery: RoutineRecoveryPolicy(window: TimeSpan.hours(2), allowsNextDay: true)
        )
        let occurrence = scheduler.occurrence(of: routine, at: date(10, 20), now: date(10, 19))

        let decision = scheduler.recoveryDecision(
            for: occurrence, routine: routine, now: date(11, 8), calendar: calendar
        )
        guard case .recover = decision else {
            return XCTFail("Friday morning should still be worth it, got \(decision)")
        }
    }

    func testARoutineWithRecoveryOffExpiresImmediately() {
        let routine = routine(recovery: .none)
        let occurrence = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))

        XCTAssertEqual(
            scheduler.recoveryDecision(
                for: occurrence, routine: routine, now: date(10, 10), calendar: calendar
            ),
            .expire
        )
    }

    func testAnOccurrenceWhoseTimeHasNotComeIsLeftAlone() {
        let routine = routine()
        let occurrence = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))

        XCTAssertEqual(
            scheduler.recoveryDecision(
                for: occurrence, routine: routine, now: date(10, 8), calendar: calendar
            ),
            .none
        )
    }

    func testASettledOccurrenceIsNeverReopened() {
        let routine = routine()
        var occurrence = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))
        occurrence.status = .completed

        XCTAssertEqual(
            scheduler.recoveryDecision(
                for: occurrence, routine: routine, now: date(10, 20), calendar: calendar
            ),
            .none
        )
    }

    // MARK: The routine itself

    /// Section 11, as a test. Missing one morning does not end the medication.
    func testMissingAnOccurrenceDoesNotDeactivateTheRoutine() {
        let routine = routine()
        var occurrence = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))
        occurrence.status = .expired

        let updated = scheduler.routine(routine, after: occurrence, at: date(10, 16))

        XCTAssertTrue(updated.isActive)
        XCTAssertEqual(updated.lastMissedAt, date(10, 9))
        XCTAssertNil(updated.lastCompletedAt)
    }

    func testCompletingAnOccurrenceRecordsItWithoutEndingTheRoutine() {
        let routine = routine()
        var occurrence = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))
        occurrence.status = .completed
        occurrence.completedAt = date(10, 9, 30)

        let updated = scheduler.routine(routine, after: occurrence, at: date(10, 10))

        XCTAssertTrue(updated.isActive)
        XCTAssertEqual(updated.lastCompletedAt, date(10, 9, 30))
    }

    /// "Skip the gym today" resolves today and leaves Wednesday alone.
    func testSkippingOneOccurrenceLeavesTheRoutineUntouched() {
        let routine = routine()
        let occurrence = scheduler.occurrence(of: routine, at: date(10, 9), now: date(10, 8))

        let skipped = scheduler.skipping(occurrence, at: date(10, 9))
        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertFalse(skipped.status.isSuccess)

        // And the routine records nothing at all: skipping is neither a success
        // nor a miss.
        XCTAssertEqual(scheduler.routine(routine, after: skipped, at: date(10, 9)), routine)
    }
}
