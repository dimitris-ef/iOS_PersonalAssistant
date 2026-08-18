import AssistantDomain
import ExecutiveSupport
import XCTest

/// The support lifecycle: what happens after a reminder is shown.
///
/// Every test here injects its own clock. Nothing waits, nothing sleeps, and
/// "four hours later" costs nothing.
final class FollowUpCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func context(at date: Date? = nil) -> SupportPlanningContext {
        SupportPlanningContext(
            profile: UserProfile(),
            preferences: SupportPreferences(),
            now: date ?? now,
            calendar: calendar
        )
    }

    // MARK: Dismissal

    /// The single most important behaviour in the product.
    func testDismissingAReminderNeverCompletesTheTask() {
        let f = makeFixture()
        let decision = FollowUpCoordinator().apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertNotEqual(decision.task.status, .completed)
        XCTAssertNil(decision.task.completedAt)
        XCTAssertFalse(decision.task.status.isTerminal)
        XCTAssertEqual(decision.task.status, .needsFollowUp)
    }

    func testDismissalRecordsTheOutcomeAndSchedulesExactlyOneFollowUp() {
        let f = makeFixture()
        let decision = FollowUpCoordinator().apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(decision.plan.stage(id: f.stage.id)?.state, .dismissed)
        XCTAssertEqual(decision.plan.stage(id: f.stage.id)?.stateChangedAt, now)
        XCTAssertEqual(decision.plan.pendingStages.count, 1)
        XCTAssertEqual(decision.schedule.count, 1)
        XCTAssertEqual(decision.plan.pendingStages.first?.kind, .followUp)
    }

    /// Support continuing is the whole milestone: a dismissed reminder has to
    /// leave something behind, not end the conversation.
    func testDismissalLeavesAFutureReminderBehind() {
        let f = makeFixture()
        let decision = FollowUpCoordinator().apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        let next = decision.plan.nextPendingStage
        XCTAssertNotNil(next?.scheduledFor)
        XCTAssertGreaterThan(next?.scheduledFor ?? .distantPast, now)
    }

    // MARK: Snooze

    func testSnoozingSchedulesTheReminderTheUserAskedFor() {
        let f = makeFixture()
        let until = now.addingTimeInterval(TimeSpan.minutes(30))

        let decision = FollowUpCoordinator().apply(
            outcome: .snoozed(until: until),
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(decision.plan.stage(id: f.stage.id)?.state, .snoozed)
        XCTAssertNotEqual(decision.task.status, .completed)
        XCTAssertEqual(decision.task.snoozeCount, 1)
        XCTAssertEqual(decision.plan.pendingStages.count, 1)
        XCTAssertEqual(decision.plan.nextPendingStage?.scheduledFor, until)
        XCTAssertEqual(decision.schedule.first?.fireDate, until)
    }

    /// Snoozing without saying when falls back to the plan's own policy rather
    /// than a number invented at the call site.
    func testSnoozingWithoutADurationUsesThePlanPolicy() {
        var f = makeFixture()
        f.plan.snooze = SnoozePolicy(defaultDuration: TimeSpan.minutes(25))

        let decision = FollowUpCoordinator().apply(
            outcome: .snoozed(until: nil),
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(
            decision.plan.nextPendingStage?.scheduledFor,
            now.addingTimeInterval(TimeSpan.minutes(25))
        )
    }

    func testSnoozingDoesNotDuplicateThePreviousReminder() {
        let f = makeFixture()
        let until = now.addingTimeInterval(TimeSpan.minutes(30))

        let decision = FollowUpCoordinator().apply(
            outcome: .snoozed(until: until),
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        // The original stage is resolved, not left waiting alongside its
        // replacement.
        XCTAssertFalse(decision.plan.stage(id: f.stage.id)?.state.isPending ?? true)
        XCTAssertEqual(decision.plan.stages.count, 2)
        XCTAssertEqual(decision.plan.pendingStages.count, 1)
    }

    // MARK: Missed

    func testAMissedReminderKeepsTheTaskOpenAndTriesAgain() {
        let f = makeFixture()
        let decision = FollowUpCoordinator().apply(
            outcome: .missed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(decision.plan.stage(id: f.stage.id)?.state, .missed)
        XCTAssertEqual(decision.task.status, .needsFollowUp)
        XCTAssertFalse(decision.task.status.isTerminal)
        XCTAssertEqual(decision.plan.pendingStages.count, 1)
        XCTAssertEqual(decision.schedule.count, 1)
    }

    /// Reconciliation: a reminder due at 10:00 with the clock at 11:00.
    func testReconciliationMarksAnOverduePendingReminderMissed() {
        var f = makeFixture()
        f.plan.stages = [overdueStage()]
        f.task.status = .reminded

        let later = now.addingTimeInterval(TimeSpan.hours(1))
        let decisions = FollowUpCoordinator().reconcile(
            task: f.task,
            plan: f.plan,
            context: context(at: later)
        )

        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.task.status, .needsFollowUp)
        XCTAssertEqual(decisions.first?.plan.stages.first?.state, .missed)
        XCTAssertEqual(decisions.first?.plan.pendingStages.count, 1)
    }

    /// A reminder cannot sit pending forever, but nor may reconciliation keep
    /// firing on the same one.
    func testReconciliationIsIdempotent() {
        var f = makeFixture()
        f.plan.stages = [overdueStage()]
        f.task.status = .reminded

        let coordinator = FollowUpCoordinator()
        let later = now.addingTimeInterval(TimeSpan.hours(1))

        let first = coordinator.reconcile(task: f.task, plan: f.plan, context: context(at: later))
        let updated = first.last
        let second = coordinator.reconcile(
            task: updated?.task ?? f.task,
            plan: updated?.plan ?? f.plan,
            // The follow-up it just created is not yet due.
            context: context(at: later)
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(updated?.plan.pendingStages.count, 1)
    }

    func testReconciliationIgnoresResolvedTasks() {
        var f = makeFixture()
        f.task.status = .completed
        f.plan.stages = [overdueStage()]

        let decisions = FollowUpCoordinator().reconcile(
            task: f.task,
            plan: f.plan,
            context: context(at: now.addingTimeInterval(TimeSpan.hours(2)))
        )
        XCTAssertTrue(decisions.isEmpty)
    }

    // MARK: Idempotency

    /// Real notification callbacks are retried. Two deliveries of the same fact
    /// must not produce two reminders.
    func testProcessingTheSameDismissalTwiceProducesOneFollowUp() {
        let f = makeFixture()
        let coordinator = FollowUpCoordinator()

        let first = coordinator.apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )
        let second = coordinator.apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: first.task,
            plan: first.plan,
            context: context()
        )

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(second.plan.pendingStages.count, 1)
        XCTAssertTrue(second.schedule.isEmpty)
        XCTAssertEqual(second.task.followUpCount, first.task.followUpCount)
    }

    /// Even a distinct stage must not produce a second equivalent follow-up at
    /// the same moment.
    func testAnEquivalentPendingFollowUpIsNotDuplicated() {
        let f = makeFixture()
        let coordinator = FollowUpCoordinator()

        let first = coordinator.apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        // A second, different stage dismissed at the same instant, on a task
        // whose attempt count has not moved on.
        var plan2 = first.plan
        let other = ReminderStage(kind: .finalCall, offset: .absolute(now), message: "again")
        plan2.stages.append(other)

        var task2 = first.task
        task2.followUpCount = f.task.followUpCount

        let second = coordinator.apply(
            outcome: .dismissed,
            toStage: other.id,
            task: task2,
            plan: plan2,
            context: context()
        )

        XCTAssertEqual(second.plan.pendingStages.filter { $0.kind == .followUp }.count, 1)
        XCTAssertTrue(second.schedule.isEmpty)
    }

    // MARK: Escalation

    /// Urgency has to mean something. Identical situations, different priority.
    func testUrgentTasksAreChasedSoonerThanLowPriorityOnes() {
        let coordinator = FollowUpCoordinator()

        func delay(for importance: Importance) -> TimeInterval {
            let f = makeFixture(importance: importance, deadline: nil)
            let decision = coordinator.apply(
                outcome: .dismissed,
                toStage: f.stage.id,
                task: f.task,
                plan: f.plan,
                context: context()
            )
            let next = decision.plan.nextPendingStage?.scheduledFor ?? now
            return next.timeIntervalSince(now)
        }

        let low = delay(for: .low)
        let normal = delay(for: .normal)
        let high = delay(for: .high)
        let critical = delay(for: .critical)

        // The semantic claim, not two arbitrary constants: the more a task
        // matters, the sooner the assistant comes back.
        XCTAssertGreaterThan(low, normal)
        XCTAssertGreaterThan(normal, high)
        XCTAssertGreaterThan(high, critical)
        XCTAssertGreaterThan(low, TimeSpan.hours(1))
        XCTAssertLessThan(critical, TimeSpan.hours(1))
    }

    func testEscalationLevelRisesWithImportance() {
        let coordinator = FollowUpCoordinator()

        func level(for importance: Importance) -> EscalationLevel {
            let f = makeFixture(importance: importance, deadline: nil)
            let decision = coordinator.apply(
                outcome: .dismissed,
                toStage: f.stage.id,
                task: f.task,
                plan: f.plan,
                context: context()
            )
            return decision.plan.nextPendingStage?.escalation ?? .gentle
        }

        XCTAssertLessThan(level(for: .low), level(for: .critical))

        // The fixture's delivered stage is `.standard`, and an unanswered
        // low-importance reminder steps up exactly one level from whatever the
        // plan has reached — it does not restart at the bottom. `.gentle`,
        // which this previously expected, is where a plan *starts*, not where
        // it goes after being ignored.
        XCTAssertEqual(level(for: .low), .insistent)

        // Importance short-circuits the ladder: anything at or above `.high`
        // goes straight to an alarm rather than climbing a step at a time.
        XCTAssertEqual(level(for: .critical), .alarm)
    }

    /// Repeated silence tightens the loop rather than repeating the same
    /// unsuccessful approach.
    func testRepeatedMissesEscalateAndComeBackSooner() {
        let f = makeFixture(importance: .high, deadline: nil)
        let coordinator = FollowUpCoordinator()

        var task = f.task
        var plan = f.plan
        var delays: [TimeInterval] = []
        var levels: [EscalationLevel] = []
        var currentStage: ReminderStage.ID? = f.stage.id
        var clock = now

        for _ in 0..<3 {
            let decision = coordinator.apply(
                outcome: .missed,
                toStage: currentStage,
                task: task,
                plan: plan,
                context: context(at: clock)
            )
            guard let next = decision.plan.nextPendingStage else { break }

            delays.append((next.scheduledFor ?? clock).timeIntervalSince(clock))
            levels.append(next.escalation)

            task = decision.task
            plan = decision.plan
            currentStage = next.id
            clock = next.scheduledFor ?? clock
        }

        XCTAssertEqual(delays.count, 3)
        XCTAssertGreaterThan(delays[0], delays[1], "each unanswered attempt should tighten the loop")
        XCTAssertGreaterThanOrEqual(delays[1], delays[2])
        XCTAssertGreaterThanOrEqual(levels[2], levels[0])
        XCTAssertEqual(task.followUpCount, 3)
    }

    /// The floor. Escalation tightens intervals; it does not remove them.
    func testFollowUpsNeverBecomeMoreFrequentThanTheMinimum() {
        var f = makeFixture(importance: .critical, deadline: nil)
        f.task.followUpCount = 20
        f.plan.followUp = FollowUpPolicy(maximumFollowUps: 99)

        let decision = FollowUpCoordinator().apply(
            outcome: .missed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        let next = decision.plan.nextPendingStage?.scheduledFor ?? now
        XCTAssertGreaterThanOrEqual(
            next.timeIntervalSince(now),
            FollowUpTiming.default.minimumInterval
        )
    }

    // MARK: Deadlines

    /// Dismissed at 9:50 PM for a 10:00 PM deadline. A four-hour follow-up
    /// would arrive long after the thing it is about.
    func testAFollowUpIsPulledInWhenTheDeadlineIsClose() {
        let deadline = now.addingTimeInterval(TimeSpan.minutes(10))
        let f = makeFixture(importance: .low, deadline: deadline)

        let decision = FollowUpCoordinator().apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        let next = decision.plan.nextPendingStage?.scheduledFor
        XCTAssertNotNil(next)
        XCTAssertLessThan(next ?? .distantFuture, deadline.addingTimeInterval(TimeSpan.minutes(5)))
    }

    /// Overdue is when support matters most; it is not when it stops.
    func testAnOverdueTaskStillGetsFollowedUp() {
        let deadline = now.addingTimeInterval(-TimeSpan.hours(3))
        let f = makeFixture(importance: .normal, deadline: deadline)

        let decision = FollowUpCoordinator().apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        let next = decision.plan.nextPendingStage?.scheduledFor
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next ?? .distantPast, now)
    }

    // MARK: Acknowledgement

    /// "I'm doing it" is not "I did it".
    func testAcknowledgingWorkDoesNotCompleteTheTask() {
        let f = makeFixture()
        let decision = FollowUpCoordinator().apply(
            outcome: .acknowledged,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(decision.task.status, .inProgress)
        XCTAssertFalse(decision.task.status.isTerminal)
        XCTAssertNil(decision.task.completedAt)
        // Pressure reduced, not removed.
        XCTAssertEqual(decision.plan.pendingStages.count, 1)
        XCTAssertGreaterThan(
            decision.plan.nextPendingStage?.scheduledFor ?? now,
            now.addingTimeInterval(TimeSpan.minutes(30))
        )
    }

    // MARK: Resolution

    func testCompletionCancelsEveryPendingReminder() {
        var f = makeFixture()
        f.plan.stages.append(
            ReminderStage(
                kind: .followUp,
                offset: .absolute(now.addingTimeInterval(600)),
                message: "later",
                scheduledFor: now.addingTimeInterval(600)
            )
        )

        let decision = FollowUpCoordinator().apply(
            outcome: .completed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(decision.task.status, .completed)
        XCTAssertEqual(decision.task.completedAt, now)
        XCTAssertTrue(decision.plan.pendingStages.isEmpty)
        XCTAssertTrue(decision.schedule.isEmpty)
        XCTAssertFalse(decision.cancel.isEmpty)
    }

    /// Dismiss at 6:00, then tap Done at 6:05 on the same sheet.
    ///
    /// The stage has already been resolved, but finishing the task is a
    /// statement about the task. Swallowing it would leave someone being chased
    /// about work they had done.
    func testCompletingThroughAnAlreadyResolvedStageStillCompletes() {
        let f = makeFixture()
        let coordinator = FollowUpCoordinator()

        let dismissed = coordinator.apply(
            outcome: .dismissed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        let completed = coordinator.apply(
            outcome: .completed,
            toStage: f.stage.id,
            task: dismissed.task,
            plan: dismissed.plan,
            context: context(at: now.addingTimeInterval(300))
        )

        XCTAssertTrue(completed.didChange)
        XCTAssertEqual(completed.task.status, .completed)
        XCTAssertTrue(completed.plan.pendingStages.isEmpty)
        XCTAssertFalse(completed.cancel.isEmpty, "the follow-up must be withdrawn")
    }

    func testCancellationStopsSupportWithoutClaimingTheWorkWasDone() {
        let f = makeFixture()
        let decision = FollowUpCoordinator().apply(
            outcome: .cancelled,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(decision.task.status, .cancelled)
        XCTAssertNotEqual(decision.task.status, .completed)
        XCTAssertNil(decision.task.completedAt)
        XCTAssertTrue(decision.plan.pendingStages.isEmpty)
        XCTAssertTrue(decision.schedule.isEmpty)
    }

    /// The 7:30 PM callback that arrives after the task was finished at 7:20.
    func testAStaleCallbackCannotReopenACompletedTask() {
        let f = makeFixture()
        let coordinator = FollowUpCoordinator()

        let completed = coordinator.apply(
            outcome: .completed,
            toStage: nil,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        for outcome in [ReminderOutcome.dismissed, .missed, .snoozed(until: nil)] {
            let stale = coordinator.apply(
                outcome: outcome,
                toStage: f.stage.id,
                task: completed.task,
                plan: completed.plan,
                context: context(at: now.addingTimeInterval(600))
            )
            XCTAssertEqual(stale.task.status, .completed, "\(outcome) must not reopen a finished task")
            XCTAssertTrue(stale.schedule.isEmpty)
            XCTAssertFalse(stale.didChange)
        }
    }

    func testAStaleCallbackCannotReviveACancelledTask() {
        var f = makeFixture()
        f.task.status = .cancelled

        let decision = FollowUpCoordinator().apply(
            outcome: .missed,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(decision.task.status, .cancelled)
        XCTAssertTrue(decision.schedule.isEmpty)
        XCTAssertFalse(decision.didChange)
    }

    /// Delivery is not an outcome. Scheduling on it would double every reminder.
    func testDeliveryAloneSchedulesNothing() {
        let f = makeFixture()
        let decision = FollowUpCoordinator().apply(
            outcome: .delivered,
            toStage: f.stage.id,
            task: f.task,
            plan: f.plan,
            context: context()
        )

        XCTAssertEqual(decision.plan.stage(id: f.stage.id)?.state, .delivered)
        XCTAssertTrue(decision.schedule.isEmpty)
        XCTAssertEqual(decision.task.status, .reminded)
    }

    // MARK: Fixtures

    /// A reminder that was due at `now` and never answered.
    private func overdueStage() -> ReminderStage {
        ReminderStage(
            kind: .followUp,
            offset: .absolute(now),
            message: "Still open",
            scheduledFor: now
        )
    }

    /// A task that has just been reminded about, and the reminder that did it.
    private struct Fixture {
        var task: TaskItem
        var plan: ReminderPlan
        var stage: ReminderStage
    }

    private func makeFixture(
        importance: Importance = .high,
        deadline: Date? = nil
    ) -> Fixture {
        let task = TaskItem(
            title: "Pay the electricity bill",
            status: .reminded,
            importance: importance,
            timing: deadline.map { .dueBy($0) } ?? .unscheduled,
            deadline: deadline,
            createdAt: now.addingTimeInterval(-TimeSpan.hours(6))
        )

        let stage = ReminderStage(
            kind: .finalCall,
            offset: .absolute(now),
            message: "Pay the electricity bill",
            requiresConfirmation: true,
            state: .delivered,
            stateChangedAt: now,
            scheduledFor: now
        )

        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(task.id),
                title: task.title,
                anchor: deadline.map { .deadline($0) } ?? .unscheduled,
                importance: importance
            ),
            stages: [stage],
            createdAt: now.addingTimeInterval(-TimeSpan.hours(6)),
            generatedBy: "test"
        )

        return Fixture(task: task, plan: plan, stage: stage)
    }
}
