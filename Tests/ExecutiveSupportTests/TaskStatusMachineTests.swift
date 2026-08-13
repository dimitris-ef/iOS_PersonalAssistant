import AssistantDomain
import XCTest
@testable import ExecutiveSupport

/// These cover the behaviour the whole product exists for: an unfinished task
/// stays the assistant's responsibility until the user actually confirms it.
final class TaskStatusMachineTests: XCTestCase {
    private let machine = TaskStatusMachine()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func task(
        status: TaskStatus = .notStarted,
        importance: Importance = .normal,
        snoozeCount: Int = 0,
        followUpCount: Int = 0
    ) -> TaskItem {
        TaskItem(
            title: "Pay the electricity bill",
            status: status,
            importance: importance,
            followUpCount: followUpCount,
            snoozeCount: snoozeCount,
            createdAt: now
        )
    }

    private func plan(
        followUp: FollowUpPolicy = FollowUpPolicy(),
        snooze: SnoozePolicy = SnoozePolicy(),
        completion: CompletionPolicy = CompletionPolicy()
    ) -> ReminderPlan {
        ReminderPlan(
            subject: ReminderSubject(
                reference: .freeform("test"),
                title: "Pay the electricity bill",
                anchor: .moment(now)
            ),
            stages: [],
            followUp: followUp,
            snooze: snooze,
            completion: completion,
            createdAt: now,
            generatedBy: "test"
        )
    }

    func testDismissingAReminderDoesNotCompleteTheTask() {
        let transition = machine.apply(
            .reminderDismissed(at: now),
            to: task(status: .reminded),
            plan: plan()
        )

        XCTAssertNotEqual(transition.status, .completed)
        XCTAssertEqual(transition.status, .needsFollowUp)
        XCTAssertEqual(transition.followUpCount, 1)
        XCTAssertNotNil(transition.followUpAt, "The assistant must schedule a check-back")
    }

    func testDismissalOnlyCompletesWhenConfirmationIsNotRequired() {
        let lenient = plan(completion: CompletionPolicy(requiresExplicitConfirmation: false))
        let transition = machine.apply(.reminderDismissed(at: now), to: task(), plan: lenient)

        XCTAssertEqual(transition.status, .reminded)
        XCTAssertNotEqual(transition.status, .completed)
    }

    func testOnlyExplicitConfirmationCompletesATask() {
        let transition = machine.apply(.confirmedComplete(at: now), to: task(), plan: plan())

        XCTAssertEqual(transition.status, .completed)
        let updated = machine.updated(task(), with: transition, at: now)
        XCTAssertEqual(updated.completedAt, now)
    }

    func testFollowUpsStopAtTheConfiguredMaximum() {
        let policy = FollowUpPolicy(maximumFollowUps: 2)
        let exhausted = task(status: .reminded, followUpCount: 2)

        let transition = machine.apply(
            .reminderDismissed(at: now),
            to: exhausted,
            plan: plan(followUp: policy)
        )

        XCTAssertEqual(transition.status, .reminded)
        XCTAssertEqual(transition.followUpCount, 2, "Should not chase beyond the limit")
        XCTAssertNil(transition.followUpAt)
    }

    func testSnoozingIncrementsAndEventuallyEscalates() {
        let policy = SnoozePolicy(maximumSnoozes: 3, escalateAfterSnoozes: 2)
        let until = now.addingTimeInterval(TimeSpan.minutes(10))

        let first = machine.apply(.snoozed(until: until), to: task(), plan: plan(snooze: policy))
        XCTAssertEqual(first.status, .snoozed)
        XCTAssertEqual(first.snoozeCount, 1)
        XCTAssertNil(first.nextEscalation)

        let second = machine.apply(
            .snoozed(until: until),
            to: task(status: .snoozed, snoozeCount: 1),
            plan: plan(snooze: policy)
        )
        XCTAssertEqual(second.snoozeCount, 2)
        XCTAssertNotNil(second.nextEscalation, "Repeated snoozing should raise the escalation")
    }

    func testRunningOutOfSnoozesForcesAnAlarmAndFollowUp() {
        let policy = SnoozePolicy(maximumSnoozes: 2)
        let transition = machine.apply(
            .snoozed(until: now.addingTimeInterval(TimeSpan.minutes(10))),
            to: task(status: .snoozed, snoozeCount: 2),
            plan: plan(snooze: policy)
        )

        XCTAssertEqual(transition.status, .needsFollowUp)
        XCTAssertEqual(transition.nextEscalation, .alarm)
    }

    func testAnUnconfirmedTaskIsMissedOnceItsMomentPasses() {
        let transition = machine.apply(
            .anchorPassed(at: now),
            to: task(status: .reminded),
            plan: plan()
        )

        XCTAssertEqual(transition.status, .missed)
        XCTAssertEqual(transition.followUpCount, 1)
        XCTAssertNotNil(transition.followUpAt)
    }

    func testCompletedTasksAreNotReopenedByLaterEvents() {
        let completed = task(status: .completed)

        XCTAssertEqual(machine.apply(.anchorPassed(at: now), to: completed, plan: plan()).status, .completed)
        XCTAssertEqual(machine.apply(.reminderDismissed(at: now), to: completed, plan: plan()).status, .completed)
        XCTAssertEqual(machine.apply(.snoozed(until: now), to: completed, plan: plan()).status, .completed)
    }

    func testStartingWorkIsTrackedSeparatelyFromFinishing() {
        let transition = machine.apply(.startedWorking(at: now), to: task(status: .reminded), plan: plan())

        XCTAssertEqual(transition.status, .inProgress)
        XCTAssertTrue(transition.status.isOutstanding)
    }

    func testHighImportanceTasksEscalateStraightToAnAlarm() {
        let transition = machine.apply(
            .reminderDismissed(at: now),
            to: task(status: .reminded, importance: .critical),
            plan: plan()
        )

        XCTAssertEqual(transition.nextEscalation, .alarm)
    }
}
