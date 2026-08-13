import AssistantDomain
import XCTest
@testable import ExecutiveSupport

final class ReminderScheduleResolverTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func plan(
        anchorOffset: TimeInterval,
        stages: [ReminderStage],
        completion: CompletionPolicy = CompletionPolicy()
    ) -> ReminderPlan {
        ReminderPlan(
            subject: ReminderSubject(
                reference: .freeform("test"),
                title: "Haircut",
                anchor: .moment(now.addingTimeInterval(anchorOffset))
            ),
            stages: stages,
            completion: completion,
            createdAt: now,
            generatedBy: "test"
        )
    }

    func testRelativeStagesResolveToConcreteDates() {
        let resolver = ReminderScheduleResolver(calendar: calendar)
        let anchorOffset = TimeSpan.days(2)
        let stage = ReminderStage(
            kind: .finalCall,
            offset: .beforeAnchor(TimeSpan.minutes(10)),
            message: "Starting soon"
        )

        let resolved = resolver.resolve(
            plan: plan(anchorOffset: anchorOffset, stages: [stage]),
            now: now
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(
            resolved[0].fireDate.timeIntervalSince1970,
            now.addingTimeInterval(anchorOffset - TimeSpan.minutes(10)).timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testStagesAlreadyInThePastAreDropped() {
        let resolver = ReminderScheduleResolver(calendar: calendar)
        let stages = [
            ReminderStage(kind: .advanceNotice, offset: .beforeAnchor(TimeSpan.days(3)), message: "Soon"),
            ReminderStage(kind: .finalCall, offset: .beforeAnchor(TimeSpan.minutes(10)), message: "Now"),
        ]

        // Anchor is only one day away, so the three-day stage is already past.
        let resolved = resolver.resolve(
            plan: plan(anchorOffset: TimeSpan.day, stages: stages),
            now: now
        )

        XCTAssertEqual(resolved.map(\.kind), [.finalCall])
    }

    func testResolvedRemindersAreOrderedByFireDate() {
        let resolver = ReminderScheduleResolver(calendar: calendar)
        let stages = [
            ReminderStage(kind: .finalCall, offset: .beforeAnchor(TimeSpan.minutes(10)), message: "Now"),
            ReminderStage(kind: .preparation, offset: .beforeAnchor(TimeSpan.hours(2)), message: "Get ready"),
        ]

        let resolved = resolver.resolve(
            plan: plan(anchorOffset: TimeSpan.days(2), stages: stages),
            now: now
        )

        XCTAssertEqual(resolved.map(\.kind), [.preparation, .finalCall])
    }

    func testCompletionPolicyForcesConfirmationOnEveryStage() {
        let resolver = ReminderScheduleResolver(calendar: calendar)
        let stage = ReminderStage(
            kind: .finalCall,
            offset: .beforeAnchor(TimeSpan.minutes(10)),
            message: "Now",
            requiresConfirmation: false
        )

        let resolved = resolver.resolve(
            plan: plan(
                anchorOffset: TimeSpan.days(1),
                stages: [stage],
                completion: CompletionPolicy(requiresExplicitConfirmation: true)
            ),
            now: now
        )

        XCTAssertEqual(resolved.first?.requiresConfirmation, true)
    }

    func testQuietHoursPushNonUrgentRemindersOut() {
        let resolver = ReminderScheduleResolver(calendar: calendar)
        // Anchor at 03:00 UTC on some future day, reminder fires right then.
        let anchor = TimeOfDay(hour: 3).resolved(
            on: now.addingTimeInterval(TimeSpan.days(2)),
            calendar: calendar
        )
        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .freeform("test"),
                title: "Quiet test",
                anchor: .moment(anchor)
            ),
            stages: [
                ReminderStage(kind: .morningOf, offset: .beforeAnchor(0), escalation: .standard, message: "Hi")
            ],
            createdAt: now,
            generatedBy: "test"
        )

        let resolved = resolver.resolve(
            plan: plan,
            now: now,
            quietHours: DayWindow(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7))
        )

        guard let fireDate = resolved.first?.fireDate else {
            return XCTFail("Expected the reminder to be rescheduled, not dropped")
        }
        XCTAssertEqual(calendar.component(.hour, from: fireDate), 7)
    }

    func testAlarmLevelRemindersIgnoreQuietHours() {
        let resolver = ReminderScheduleResolver(calendar: calendar)
        let anchor = TimeOfDay(hour: 3).resolved(
            on: now.addingTimeInterval(TimeSpan.days(2)),
            calendar: calendar
        )
        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .freeform("test"),
                title: "Wake up",
                anchor: .moment(anchor)
            ),
            stages: [
                ReminderStage(kind: .finalCall, offset: .beforeAnchor(0), escalation: .alarm, message: "Up")
            ],
            createdAt: now,
            generatedBy: "test"
        )

        let resolved = resolver.resolve(
            plan: plan,
            now: now,
            quietHours: DayWindow(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7))
        )

        XCTAssertEqual(calendar.component(.hour, from: resolved[0].fireDate), 3)
    }
}
