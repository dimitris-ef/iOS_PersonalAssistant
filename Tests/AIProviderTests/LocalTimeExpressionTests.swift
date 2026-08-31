import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal

/// Turning what a person said about time into an instant.
///
/// ## The failure these exist for
///
/// A reminder requested on a real phone came back with a due date in 2023. The
/// model had been shown a `dueDate` field of `format: date-time` and no way to
/// know what day it was, so it produced something shaped like an answer.
///
/// Under the semantic protocol it is never asked. It says "in 10 minutes" and
/// this resolves that against the app's own clock — which means the arithmetic
/// below is now the only place a due date can be wrong, and every case of it is
/// pinned to a fixed instant here.
final class LocalTimeExpressionTests: XCTestCase {

    /// 31 August 2026, 14:20, Europe/Athens (UTC+3 in August).
    private static let athens = TimeZone(identifier: "Europe/Athens")!
    private static let now = Date(timeIntervalSince1970: 1_788_175_200)

    private var resolver: LocalTimeExpressionResolver {
        LocalTimeExpressionResolver(
            dateProvider: FixedDateProvider(now: Self.now, timeZone: Self.athens)
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.athens
        return calendar
    }

    private func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private func resolved(_ expression: String, file: StaticString = #filePath, line: UInt = #line)
        throws -> Date {
        switch resolver.resolve(expression) {
        case .resolved(let value):
            return value.date
        case .notUnderstood(let reason):
            XCTFail("\"\(expression)\" was not understood: \(reason)", file: file, line: line)
            throw XCTSkip("unresolved")
        }
    }

    // MARK: The verification case

    /// Section 67, exactly as written: clock at 14:20 Athens, "in 10 minutes",
    /// due at 14:30 Athens.
    func testInTenMinutesResolvesAgainstTheInjectedClock() throws {
        let date = try resolved("in 10 minutes")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_788_175_800))

        let parts = components(date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 31)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 30)
    }

    /// The same words, the same instant, a different device time zone — and a
    /// different answer, correctly. This is the fact a model cannot know and is
    /// the reason it is never asked to produce a timestamp.
    func testAWallClockExpressionDependsOnTheDeviceTimeZone() throws {
        let tokyoZone = TimeZone(identifier: "Asia/Tokyo")!
        let tokyo = LocalTimeExpressionResolver(
            dateProvider: FixedDateProvider(now: Self.now, timeZone: tokyoZone)
        )
        guard
            case .resolved(let here) = resolver.resolve("tomorrow at 3"),
            case .resolved(let there) = tokyo.resolve("tomorrow at 3")
        else {
            return XCTFail("expected both to resolve")
        }

        XCTAssertNotEqual(here.date, there.date)
        XCTAssertEqual(components(here.date).hour, 15)
        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = tokyoZone
        XCTAssertEqual(tokyoCalendar.dateComponents([.hour], from: there.date).hour, 15)
    }

    /// A relative offset, by contrast, is the same instant everywhere.
    func testARelativeOffsetIsTimeZoneIndependent() throws {
        let tokyo = LocalTimeExpressionResolver(
            dateProvider: FixedDateProvider(
                now: Self.now, timeZone: TimeZone(identifier: "Asia/Tokyo")!
            )
        )
        guard case .resolved(let value) = tokyo.resolve("in 10 minutes") else {
            return XCTFail("expected a resolution")
        }
        XCTAssertEqual(value.date, Date(timeIntervalSince1970: 1_788_175_800))
        XCTAssertEqual(value.reading, .relativeOffset)
    }

    // MARK: Relative

    func testRelativeOffsets() throws {
        XCTAssertEqual(try resolved("in 1 minute"), Self.now.addingTimeInterval(60))
        XCTAssertEqual(try resolved("in 90 minutes"), Self.now.addingTimeInterval(5400))
        XCTAssertEqual(try resolved("in 2 hours"), Self.now.addingTimeInterval(7200))
        XCTAssertEqual(try resolved("in half an hour"), Self.now.addingTimeInterval(1800))
        XCTAssertEqual(try resolved("in an hour and a half"), Self.now.addingTimeInterval(5400))
        XCTAssertEqual(try resolved("in ten minutes"), Self.now.addingTimeInterval(600))
    }

    // MARK: Days and times

    func testTomorrowAtThreeIsTheAfternoon() throws {
        let parts = components(try resolved("tomorrow at 3"))
        XCTAssertEqual(parts.day, 1)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.hour, 15)
        XCTAssertEqual(parts.minute, 0)
    }

    func testAnExplicitMeridiemIsTakenLiterally() throws {
        let parts = components(try resolved("tomorrow at 8 am"))
        XCTAssertEqual(parts.day, 1)
        XCTAssertEqual(parts.hour, 8)
    }

    /// A bare hour today picks whichever reading is still ahead: at 14:20,
    /// "at 5 PM" and "at 5" are both this afternoon.
    func testABareHourTodayPicksTheNextOneToCome() throws {
        let explicit = components(try resolved("at 5 PM"))
        XCTAssertEqual(explicit.day, 31)
        XCTAssertEqual(explicit.hour, 17)

        let bare = components(try resolved("at 5"))
        XCTAssertEqual(bare.day, 31)
        XCTAssertEqual(bare.hour, 17)
    }

    /// A time that has gone by today, with no day named, is tomorrow.
    func testATimeAlreadyPassedRollsToTheNextDay() throws {
        let parts = components(try resolved("at 9 am"))
        XCTAssertEqual(parts.day, 1)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.hour, 9)
    }

    func testTonightHasItsOwnHour() throws {
        let parts = components(try resolved("tonight"))
        XCTAssertEqual(parts.day, 31)
        XCTAssertEqual(parts.hour, 20)
    }

    func testNextMondayIsTheFollowingMonday() throws {
        let date = try resolved("next monday at 10 am")
        let parts = calendar.dateComponents([.weekday, .day, .month, .hour], from: date)
        XCTAssertEqual(parts.weekday, 2)
        XCTAssertEqual(parts.hour, 10)
        // 31 August 2026 is itself a Monday, so "next Monday" must be the 7th.
        XCTAssertEqual(parts.day, 7)
        XCTAssertEqual(parts.month, 9)
    }

    func testANamedCalendarDate() throws {
        let parts = components(try resolved("September 5 at 18:00"))
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 5)
        XCTAssertEqual(parts.hour, 18)
        XCTAssertEqual(parts.minute, 0)
    }

    /// A date already gone this year means next year, not seven months ago.
    func testAPastCalendarDateRollsToNextYear() throws {
        let parts = components(try resolved("March 3 at 9 am"))
        XCTAssertEqual(parts.year, 2027)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 3)
    }

    // MARK: Refusals

    /// The important half. Nothing here invents a time, so a request the
    /// resolver cannot read becomes a question rather than a wrong reminder.
    func testUnreadableExpressionsAreRefusedRatherThanGuessed() {
        for expression in ["", "soon", "later", "when I get a chance", "sometime"] {
            guard case .notUnderstood = resolver.resolve(expression) else {
                return XCTFail("\"\(expression)\" should not have resolved to an instant")
            }
        }
    }

    /// A named day whose time has gone is refused too: rolling "today at 9" to
    /// tomorrow would be the app choosing a day the user did not.
    func testANamedDayWhoseTimeHasPassedIsRefused() {
        guard case .notUnderstood = resolver.resolve("today at 9 am") else {
            return XCTFail("a past time on a named day must not be silently moved")
        }
    }

    /// Every resolved instant is in the future. Stated as a property rather
    /// than a case, because "a due date in the past" is the device failure.
    func testNoExpressionEverResolvesIntoThePast() {
        let expressions = [
            "in 10 minutes", "in 2 hours", "tomorrow at 3", "at 5 pm", "at 9 am",
            "tonight", "next monday at 10 am", "September 5 at 18:00",
            "March 3 at 9 am", "in 3 days at 8 am", "tomorrow morning",
        ]
        for expression in expressions {
            guard case .resolved(let value) = resolver.resolve(expression) else { continue }
            XCTAssertGreaterThan(
                value.date, Self.now, "\"\(expression)\" resolved into the past"
            )
        }
    }

    // MARK: Durations

    func testDurations() {
        XCTAssertEqual(resolver.resolveDuration("for an hour"), 3600)
        XCTAssertEqual(resolver.resolveDuration("30 minutes"), 1800)
        XCTAssertEqual(resolver.resolveDuration("half an hour"), 1800)
        XCTAssertEqual(resolver.resolveDuration("for 2 hours"), 7200)
        XCTAssertNil(resolver.resolveDuration("a while"))
        XCTAssertNil(resolver.resolveDuration(""))
    }
}
