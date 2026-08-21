#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import XCTest

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class TaskPersistenceTests: PersistenceTestCase {

    // MARK: Save and load

    func testSavesEveryFieldOfATask() async throws {
        let task = TaskItem(
            title: "Call the dentist",
            details: "Ask about the Thursday slot",
            status: .inProgress,
            importance: .high,
            timing: .fixed(Self.referenceDate.addingTimeInterval(3_600)),
            deadline: Self.referenceDate.addingTimeInterval(7_200),
            preparationDuration: TimeSpan.minutes(20),
            travelDuration: TimeSpan.minutes(15),
            linkedCalendarItemID: CalendarItem.ID(),
            reminderPlanID: ReminderPlan.ID(),
            followUpCount: 2,
            snoozeCount: 1,
            createdAt: Self.referenceDate,
            updatedAt: Self.referenceDate.addingTimeInterval(30),
            completedAt: nil
        )
        try await repositories.tasks.save(task)

        try relaunch()

        let stored = try await repositories.tasks.task(id: task.id)
        let loaded = try XCTUnwrap(stored)
        // Compared whole rather than field by field: a new domain field that
        // the mapper forgets should fail this test, and a hand-written list of
        // assertions is exactly what would not notice.
        XCTAssertEqual(loaded, task)
    }

    func testRoundTripsEveryTimingCase() async throws {
        let window = TimeWindow(
            start: Self.referenceDate,
            end: Self.referenceDate.addingTimeInterval(TimeSpan.days(3))
        )
        let cases: [TimingPreference] = [
            .fixed(Self.referenceDate),
            .flexible(window),
            .dueBy(Self.referenceDate.addingTimeInterval(600)),
            .unscheduled,
        ]

        for timing in cases {
            let task = TaskItem(title: "t", timing: timing, createdAt: Self.referenceDate)
            try await repositories.tasks.save(task)
            let stored = try await repositories.tasks.task(id: task.id)
            let loaded = try XCTUnwrap(stored)
            XCTAssertEqual(loaded.timing, timing)
        }
    }

    /// Recurrence belongs to a routine, not to a task.
    ///
    /// A task used to carry its own rule, which could not express the thing that
    /// matters: yesterday's dose was missed and today's was taken. Occurrences
    /// are separate tasks now, and the rule that generates them lives on the
    /// routine — so this is where the round trip has to hold.
    func testRoundTripsEveryRecurrenceCase() async throws {
        let cases: [RecurrenceRule] = [
            RecurrenceRule(
                frequency: .daily,
                timeOfDay: TimeOfDay(hour: 9),
                startDate: Self.referenceDate
            ),
            RecurrenceRule(
                frequency: .weekly,
                interval: 2,
                weekdays: [1, 3, 5],
                timeOfDay: TimeOfDay(hour: 20, minute: 30),
                startDate: Self.referenceDate
            ),
            RecurrenceRule(
                frequency: .monthly,
                dayOfMonth: 14,
                timeOfDay: TimeOfDay(hour: 7, minute: 5),
                startDate: Self.referenceDate,
                endDate: Self.referenceDate.addingTimeInterval(TimeSpan.days(400))
            ),
        ]

        for rule in cases {
            let routine = Routine(title: "r", recurrence: rule, createdAt: Self.referenceDate)
            try await repositories.routines.save(routine)
            let stored = try await repositories.routines.routine(id: routine.id)
            let loaded = try XCTUnwrap(stored)
            XCTAssertEqual(loaded.recurrence, rule)
        }
    }

    /// An occurrence is an ordinary task that knows where it came from.
    func testRoundTripsAnOccurrencesLinkToItsRoutine() async throws {
        let routineID = Routine.ID()
        let when = Self.referenceDate.addingTimeInterval(TimeSpan.hours(9))
        let task = TaskItem(
            title: "Take medication",
            timing: .fixed(when),
            estimatedDuration: TimeSpan.minutes(2),
            routineID: routineID,
            occurrenceDate: when,
            preparationSteps: [
                PreparationStep(title: "Fill the glass", estimatedDuration: TimeSpan.minutes(1))
            ],
            createdAt: Self.referenceDate
        )
        try await repositories.tasks.save(task)

        try relaunch()

        let loaded = try XCTUnwrap(try await repositories.tasks.task(id: task.id))
        XCTAssertEqual(loaded, task)
        XCTAssertTrue(loaded.isRoutineOccurrence)
    }

    // MARK: Status

    /// The distinction the product exists for.
    ///
    /// A reminder that was delivered and swiped away leaves a task `reminded`,
    /// not `completed`. If persistence collapsed those two, relaunching the app
    /// would silently mark work done that nobody did.
    func testDismissedAndCompletedRemainDifferentAfterAReopen() async throws {
        let dismissed = TaskItem(
            title: "Pay the electricity bill",
            status: .reminded,
            createdAt: Self.referenceDate
        )
        let done = TaskItem(
            title: "Book train tickets",
            status: .completed,
            createdAt: Self.referenceDate,
            completedAt: Self.referenceDate.addingTimeInterval(120)
        )
        try await repositories.tasks.save(dismissed)
        try await repositories.tasks.save(done)

        try relaunch()

        let dismissedRow = try await repositories.tasks.task(id: dismissed.id)
        let doneRow = try await repositories.tasks.task(id: done.id)
        let reloadedDismissed = try XCTUnwrap(dismissedRow)
        let reloadedDone = try XCTUnwrap(doneRow)

        XCTAssertEqual(reloadedDismissed.status, .reminded)
        XCTAssertTrue(reloadedDismissed.status.isOutstanding)
        XCTAssertNil(reloadedDismissed.completedAt)

        XCTAssertEqual(reloadedDone.status, .completed)
        XCTAssertFalse(reloadedDone.status.isOutstanding)
        XCTAssertNotNil(reloadedDone.completedAt)
    }

    func testEveryStatusSurvives() async throws {
        for status in TaskStatus.allCases {
            let task = TaskItem(title: "t", status: status, createdAt: Self.referenceDate)
            try await repositories.tasks.save(task)
            let stored = try await repositories.tasks.task(id: task.id)
            let loaded = try XCTUnwrap(stored)
            XCTAssertEqual(loaded.status, status)
        }
    }

    // MARK: Updating

    func testUpdatingATaskOverwritesTheStoredOne() async throws {
        var task = TaskItem(title: "Draft", createdAt: Self.referenceDate)
        try await repositories.tasks.save(task)

        task.title = "Call the dentist"
        task.status = .completed
        task.completedAt = Self.referenceDate.addingTimeInterval(60)
        task.updatedAt = Self.referenceDate.addingTimeInterval(60)
        try await repositories.tasks.save(task)

        try relaunch()

        let all = try await repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(all.count, 1, "a second save must update, not insert")
        XCTAssertEqual(all.first?.title, "Call the dentist")
        XCTAssertEqual(all.first?.status, .completed)
    }

    // MARK: Deleting

    func testDeletingATaskRemovesIt() async throws {
        let task = TaskItem(title: "Temporary", createdAt: Self.referenceDate)
        try await repositories.tasks.save(task)
        try await repositories.tasks.delete(id: task.id)

        try relaunch()

        let reloaded = try await repositories.tasks.task(id: task.id)
        let remaining = try await repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertNil(reloaded)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: Filtering and ordering

    func testFilteringMatchesTheDomainRules() async throws {
        let outstanding = TaskItem(
            title: "Outstanding",
            status: .notStarted,
            importance: .high,
            createdAt: Self.referenceDate
        )
        let finished = TaskItem(
            title: "Finished",
            status: .completed,
            createdAt: Self.referenceDate
        )
        let unimportant = TaskItem(
            title: "Unimportant",
            status: .notStarted,
            importance: .low,
            createdAt: Self.referenceDate
        )
        for task in [outstanding, finished, unimportant] {
            try await repositories.tasks.save(task)
        }

        let open = try await repositories.tasks.tasks(matching: .outstanding)
        XCTAssertEqual(Set(open.map(\.title)), ["Outstanding", "Unimportant"])

        let important = try await repositories.tasks.tasks(
            matching: TaskFilter(minimumImportance: .high)
        )
        XCTAssertEqual(important.map(\.title), ["Outstanding"])

        let limited = try await repositories.tasks.tasks(matching: TaskFilter(limit: 1))
        XCTAssertEqual(limited.count, 1)
    }

    func testTasksAreOrderedByWhenTheyAreDue() async throws {
        let soon = TaskItem(
            title: "Soon",
            timing: .fixed(Self.referenceDate.addingTimeInterval(60)),
            createdAt: Self.referenceDate
        )
        let later = TaskItem(
            title: "Later",
            timing: .fixed(Self.referenceDate.addingTimeInterval(6_000)),
            createdAt: Self.referenceDate
        )
        let never = TaskItem(title: "Unscheduled", createdAt: Self.referenceDate)

        // Saved out of order on purpose.
        for task in [never, later, soon] {
            try await repositories.tasks.save(task)
        }

        try relaunch()

        let ordered = try await repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(ordered.map(\.title), ["Soon", "Later", "Unscheduled"])
    }
}

#endif
