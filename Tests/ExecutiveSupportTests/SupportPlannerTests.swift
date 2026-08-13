import AssistantDomain
import XCTest
@testable import ExecutiveSupport

final class SupportPlannerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2023-11-14 22:13:20 UTC — an arbitrary but fixed "now".
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func context(
        preferences: SupportPreferences = SupportPreferences(),
        profile: UserProfile = UserProfile(defaultPreparationDuration: Duration.minutes(30))
    ) -> SupportPlanningContext {
        SupportPlanningContext(
            profile: profile,
            preferences: preferences,
            now: now,
            calendar: calendar
        )
    }

    private func haircutSubject(daysAhead: Double = 7) -> ReminderSubject {
        ReminderSubject(
            reference: .calendarItem(CalendarItem.ID()),
            title: "Haircut",
            anchor: .moment(now.addingTimeInterval(Duration.days(daysAhead))),
            importance: .normal,
            preparationDuration: Duration.minutes(30),
            travelDuration: Duration.minutes(20),
            isTimeFixed: true
        )
    }

    func testFixedAppointmentGetsTheFullStagedPlan() {
        let plan = DefaultSupportPlanner().makePlan(for: haircutSubject(), context: context())
        let kinds = Set(plan.stages.map(\.kind))

        XCTAssertTrue(kinds.contains(.advanceNotice))
        XCTAssertTrue(kinds.contains(.morningOf))
        XCTAssertTrue(kinds.contains(.preparation))
        XCTAssertTrue(kinds.contains(.leave))
        XCTAssertTrue(kinds.contains(.finalCall))
    }

    func testPreparationStageAccountsForTravelOnTopOfGettingReady() {
        let plan = DefaultSupportPlanner().makePlan(for: haircutSubject(), context: context())

        guard let preparation = plan.stages.first(where: { $0.kind == .preparation }),
              case .beforeAnchor(let lead) = preparation.offset else {
            return XCTFail("Expected a preparation stage with a relative offset")
        }
        // 30 minutes getting ready + 20 minutes travelling.
        XCTAssertEqual(lead, Duration.minutes(50), accuracy: 1)
    }

    func testNoLeaveStageWhenThereIsNowhereToTravel() {
        var subject = haircutSubject()
        subject.travelDuration = 0

        let plan = DefaultSupportPlanner().makePlan(for: subject, context: context())

        XCTAssertFalse(plan.stages.contains { $0.kind == .leave })
        XCTAssertTrue(plan.stages.contains { $0.kind == .preparation })
    }

    func testAdvanceNoticeIsSkippedWhenItWouldAlreadyBeInThePast() {
        // The appointment is two hours away, so a three-day warning is moot.
        let plan = DefaultSupportPlanner().makePlan(
            for: haircutSubject(daysAhead: 2.0 / 24.0),
            context: context()
        )

        XCTAssertFalse(plan.stages.contains { $0.kind == .advanceNotice })
        XCTAssertTrue(plan.stages.contains { $0.kind == .finalCall })
    }

    func testReminderStrategyIsDrivenByPreferencesNotHardcoded() {
        var preferences = SupportPreferences()
        preferences.advanceNoticeDays = [5, 2]

        let plan = DefaultSupportPlanner().makePlan(
            for: haircutSubject(daysAhead: 10),
            context: context(preferences: preferences)
        )

        let advanceOffsets = plan.stages
            .filter { $0.kind == .advanceNotice }
            .compactMap { stage -> Int? in
                if case .daysBefore(let days, _) = stage.offset { return days }
                return nil
            }
        XCTAssertEqual(Set(advanceOffsets), [5, 2])
    }

    func testCriticalImportanceRaisesEscalationToAlarm() {
        var subject = haircutSubject()
        subject.importance = .critical

        let plan = DefaultSupportPlanner().makePlan(for: subject, context: context())
        let finalCall = plan.stages.first { $0.kind == .finalCall }

        XCTAssertEqual(finalCall?.escalation, .alarm)
    }

    func testFlexibleWorkGetsNudgesInsteadOfLeaveAndPreparation() {
        let subject = ReminderSubject(
            reference: .task(TaskItem.ID()),
            title: "Pay the electricity bill",
            anchor: .window(
                TimeWindow(start: now, end: now.addingTimeInterval(Duration.days(5)))
            ),
            importance: .normal,
            isTimeFixed: false
        )

        let plan = DefaultSupportPlanner().makePlan(for: subject, context: context())
        let kinds = Set(plan.stages.map(\.kind))

        XCTAssertTrue(kinds.contains(.nudge))
        XCTAssertFalse(kinds.contains(.leave))
        XCTAssertFalse(kinds.contains(.preparation))
    }

    func testUnscheduledSubjectsProduceNoStages() {
        let subject = ReminderSubject(
            reference: .freeform("someday"),
            title: "Learn the guitar",
            anchor: .unscheduled
        )

        let plan = DefaultSupportPlanner().makePlan(for: subject, context: context())
        XCTAssertTrue(plan.stages.isEmpty)
    }

    func testPlansRecordWhichPlannerMadeThem() {
        let planner = DefaultSupportPlanner()
        let plan = planner.makePlan(for: haircutSubject(), context: context())
        XCTAssertEqual(plan.generatedBy, planner.identifier)
    }
}
