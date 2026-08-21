import AssistantDomain
import XCTest

/// Recurrence: the rules, the dates they produce, and the ones they refuse.
///
/// Every test here fixes its own calendar and its own clock. Nothing sleeps and
/// nothing reads `Date()` — section 97, and the only way a daylight-saving test
/// can mean anything.
final class RecurrenceTests: XCTestCase {

    /// Europe/London, because it is the zone whose clocks change on dates this
    /// test can name, and because the bug being guarded against — adding 86,400
    /// seconds — is invisible everywhere else for 363 days of the year.
    private var london: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0,
        in calendar: Calendar? = nil
    ) -> Date {
        let calendar = calendar ?? london
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    // MARK: Validation

    func testAnIntervalBelowOneIsRejected() {
        let rule = RecurrenceRule(
            frequency: .daily,
            interval: 0,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 3, 1)
        )
        XCTAssertThrowsError(try rule.validate()) { error in
            XCTAssertEqual(error as? RecurrenceRule.ValidationError, .nonPositiveInterval(0))
        }
    }

    func testAWeeklyRuleWithNoWeekdaysIsRejected() {
        let rule = RecurrenceRule(
            frequency: .weekly,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 3, 1)
        )
        XCTAssertThrowsError(try rule.validate()) { error in
            XCTAssertEqual(error as? RecurrenceRule.ValidationError, .weeklyRuleWithoutWeekdays)
        }
    }

    func testAnImpossibleWeekdayIsRejected() {
        let rule = RecurrenceRule(
            frequency: .weekly,
            weekdays: [3, 9],
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 3, 1)
        )
        XCTAssertThrowsError(try rule.validate()) { error in
            XCTAssertEqual(error as? RecurrenceRule.ValidationError, .weekdayOutOfRange(9))
        }
    }

    func testADayOfMonthOutsideAMonthIsRejected() {
        let rule = RecurrenceRule(
            frequency: .monthly,
            dayOfMonth: 45,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 3, 1)
        )
        XCTAssertThrowsError(try rule.validate()) { error in
            XCTAssertEqual(error as? RecurrenceRule.ValidationError, .dayOfMonthOutOfRange(45))
        }
    }

    func testARuleThatEndsBeforeItStartsIsRejected() {
        let rule = RecurrenceRule(
            frequency: .daily,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 3, 10),
            endDate: date(2026, 3, 1)
        )
        XCTAssertThrowsError(try rule.validate()) { error in
            XCTAssertEqual(error as? RecurrenceRule.ValidationError, .endBeforeStart)
        }
    }

    // MARK: Daily

    func testADailyRuleProducesTheSameWallClockTimeAcrossADaylightSavingChange() {
        // British Summer Time begins at 01:00 on 29 March 2026: the clocks go
        // forward, and that day is 23 hours long.
        let rule = RecurrenceRule(
            frequency: .daily,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 3, 27)
        )

        let occurrences = rule.occurrences(
            in: TimeWindow(start: date(2026, 3, 28), end: date(2026, 3, 31)),
            calendar: london,
            limit: 10
        )

        XCTAssertEqual(occurrences, [
            date(2026, 3, 28, 9),
            date(2026, 3, 29, 9),
            date(2026, 3, 30, 9),
        ])

        // The proof that the maths is calendar-based: nine o'clock on the day
        // the clocks change is 23 hours after nine o'clock the day before, not
        // 24. Adding 86,400 seconds would have produced 10:00.
        let gap = occurrences[1].timeIntervalSince(occurrences[0])
        XCTAssertEqual(gap, TimeSpan.hours(23), accuracy: 1)
    }

    func testAnEveryOtherDayRuleKeepsItsRhythm() {
        let rule = RecurrenceRule(
            frequency: .daily,
            interval: 2,
            timeOfDay: TimeOfDay(hour: 7),
            startDate: date(2026, 6, 1)
        )

        let occurrences = rule.occurrences(
            in: TimeWindow(start: date(2026, 6, 1), end: date(2026, 6, 8)),
            calendar: london,
            limit: 10
        )

        XCTAssertEqual(occurrences, [
            date(2026, 6, 1, 7),
            date(2026, 6, 3, 7),
            date(2026, 6, 5, 7),
            date(2026, 6, 7, 7),
        ])
    }

    // MARK: Weekly

    func testAWeeklyRuleOnlyFallsOnItsChosenDays() {
        // 1 June 2026 is a Monday. Weekday 2 = Monday, 5 = Thursday.
        let rule = RecurrenceRule(
            frequency: .weekly,
            weekdays: [2, 5],
            timeOfDay: TimeOfDay(hour: 20),
            startDate: date(2026, 6, 1)
        )

        let occurrences = rule.occurrences(
            in: TimeWindow(start: date(2026, 6, 1), end: date(2026, 6, 12)),
            calendar: london,
            limit: 10
        )

        XCTAssertEqual(occurrences, [
            date(2026, 6, 1, 20),
            date(2026, 6, 4, 20),
            date(2026, 6, 8, 20),
            date(2026, 6, 11, 20),
        ])
    }

    /// "Every other Thursday" has to stay fortnightly, not drift whenever a
    /// month boundary lands mid-week.
    func testAFortnightlyRuleStaysOnTheSameRhythm() {
        let rule = RecurrenceRule(
            frequency: .weekly,
            interval: 2,
            weekdays: [5],
            timeOfDay: TimeOfDay(hour: 18),
            startDate: date(2026, 6, 4)
        )

        let occurrences = rule.occurrences(
            in: TimeWindow(start: date(2026, 6, 1), end: date(2026, 7, 20)),
            calendar: london,
            limit: 10
        )

        XCTAssertEqual(occurrences, [
            date(2026, 6, 4, 18),
            date(2026, 6, 18, 18),
            date(2026, 7, 2, 18),
            date(2026, 7, 16, 18),
        ])
    }

    // MARK: Monthly

    func testAMonthlyRuleFallsOnItsDay() {
        let rule = RecurrenceRule(
            frequency: .monthly,
            dayOfMonth: 14,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 1, 1)
        )

        let occurrences = rule.occurrences(
            in: TimeWindow(start: date(2026, 1, 1), end: date(2026, 4, 1)),
            calendar: london,
            limit: 10
        )

        XCTAssertEqual(occurrences, [
            date(2026, 1, 14, 9),
            date(2026, 2, 14, 9),
            date(2026, 3, 14, 9),
        ])
    }

    /// A rule whose day does not exist in a given month simply skips it rather
    /// than searching forever or silently sliding to the 28th.
    func testAMonthlyRuleOnTheThirtyFirstSkipsShortMonths() {
        let rule = RecurrenceRule(
            frequency: .monthly,
            dayOfMonth: 31,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 1, 1)
        )

        let occurrences = rule.occurrences(
            in: TimeWindow(start: date(2026, 1, 1), end: date(2026, 5, 1)),
            calendar: london,
            limit: 10
        )

        XCTAssertEqual(occurrences, [
            date(2026, 1, 31, 9),
            date(2026, 3, 31, 9),
        ])
    }

    // MARK: Bounds

    func testGenerationIsBoundedByTheRequestedLimit() {
        let rule = RecurrenceRule(
            frequency: .daily,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 1, 1)
        )

        // A ten-year window. Without the limit this is 3,650 records nobody
        // asked for.
        let occurrences = rule.occurrences(
            in: TimeWindow(start: date(2026, 1, 1), end: date(2036, 1, 1)),
            calendar: london,
            limit: 4
        )

        XCTAssertEqual(occurrences.count, 4)
    }

    func testNothingIsProducedAfterTheRuleEnds() {
        let rule = RecurrenceRule(
            frequency: .daily,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 6, 1),
            endDate: date(2026, 6, 3, 12)
        )

        let occurrences = rule.occurrences(
            in: TimeWindow(start: date(2026, 6, 1), end: date(2026, 6, 30)),
            calendar: london,
            limit: 30
        )

        XCTAssertEqual(occurrences, [
            date(2026, 6, 1, 9),
            date(2026, 6, 2, 9),
            date(2026, 6, 3, 9),
        ])
        XCTAssertNil(rule.occurrence(onOrAfter: date(2026, 6, 4), calendar: london))
    }

    func testNothingIsProducedBeforeTheRuleStarts() {
        let rule = RecurrenceRule(
            frequency: .daily,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 6, 10)
        )
        XCTAssertEqual(
            rule.occurrence(onOrAfter: date(2026, 6, 1), calendar: london),
            date(2026, 6, 10, 9)
        )
    }

    func testAnInvalidRuleProducesNothingRatherThanLoopingForever() {
        let rule = RecurrenceRule(
            frequency: .weekly,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 6, 1)
        )
        XCTAssertFalse(rule.isValid)
        XCTAssertNil(rule.occurrence(onOrAfter: date(2026, 6, 1), calendar: london))
    }

    // MARK: Occurrence identity

    /// The property idempotent generation rests on: working out that Thursday
    /// needs an occurrence twice must produce the same record, not two.
    func testAnOccurrenceIdentityIsDerivedFromTheRoutineAndTheMoment() {
        let routine = Routine(
            title: "Take medication",
            recurrence: RecurrenceRule(
                frequency: .daily,
                timeOfDay: TimeOfDay(hour: 9),
                startDate: date(2026, 6, 1)
            ),
            createdAt: date(2026, 6, 1)
        )

        let monday = date(2026, 6, 1, 9)
        let tuesday = date(2026, 6, 2, 9)

        XCTAssertEqual(routine.occurrenceID(at: monday), routine.occurrenceID(at: monday))
        XCTAssertNotEqual(routine.occurrenceID(at: monday), routine.occurrenceID(at: tuesday))

        // And different routines never collide on the same instant.
        var other = routine
        other.id = Routine.ID()
        XCTAssertNotEqual(routine.occurrenceID(at: monday), other.occurrenceID(at: monday))
    }

    // MARK: Description

    func testASummaryReadsAsAPhrase() {
        let daily = RecurrenceRule(
            frequency: .daily,
            timeOfDay: TimeOfDay(hour: 9),
            startDate: date(2026, 6, 1)
        )
        XCTAssertEqual(daily.summary(calendar: london), "Every day at 09:00")

        let weekly = RecurrenceRule(
            frequency: .weekly,
            weekdays: [5],
            timeOfDay: TimeOfDay(hour: 20),
            startDate: date(2026, 6, 4)
        )
        XCTAssertTrue(weekly.summary(calendar: london).contains("20:00"))
        XCTAssertTrue(weekly.summary(calendar: london).contains("Thursday"))
    }
}
