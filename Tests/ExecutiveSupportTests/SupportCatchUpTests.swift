import AssistantDomain
import XCTest

@testable import ExecutiveSupport

/// What happens when the app has been away.
///
/// The scenario the whole milestone is built around: the process is not running,
/// reminders come due anyway, and eventually the user opens the app. Everything
/// here is pure — an injected clock and no I/O — so "a week later" costs nothing
/// and the compression behaviour can be asserted exactly rather than sampled.
final class SupportCatchUpTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func context(at date: Date) -> SupportPlanningContext {
        SupportPlanningContext(
            profile: UserProfile(),
            preferences: SupportPreferences(),
            now: date,
            calendar: calendar
        )
    }

    // MARK: The grace period

    /// Section 31. A reminder that has just fired is not a reminder that was
    /// missed — the user may well be looking at it. Without this window, tapping
    /// a notification launches the app, which reconciles, which marks the stage
    /// missed a fraction of a second after it appeared.
    func testAStageThatJustFiredIsNotYetMissed() {
        let policy = SupportCatchUpPolicy()
        let stage = pendingStage(due: now)

        XCTAssertFalse(policy.isOverdue(stage, at: now))
        XCTAssertFalse(policy.isOverdue(stage, at: now.addingTimeInterval(30)))
        XCTAssertTrue(policy.isOverdue(stage, at: now.addingTimeInterval(TimeSpan.minutes(5))))
    }

    /// Only pending stages can be missed. One the user already answered has an
    /// outcome, and reconciliation must not overwrite it with a worse one.
    func testAnAnsweredStageIsNeverMissedHoweverLongAgoItWas() {
        let policy = SupportCatchUpPolicy()
        let aWeek = now.addingTimeInterval(TimeSpan.days(7))

        for state in [ReminderStageState.dismissed, .acknowledged, .snoozed, .cancelled, .missed] {
            var stage = pendingStage(due: now)
            stage.state = state
            XCTAssertFalse(
                policy.isOverdue(stage, at: aWeek),
                "\(state) is an answer — reconciliation must not re-decide it"
            )
        }
    }

    /// A stage with no date has not been scheduled and cannot have been missed.
    func testAnUnscheduledStageIsNotOverdue() {
        var stage = pendingStage(due: now)
        stage.scheduledFor = nil
        XCTAssertFalse(SupportCatchUpPolicy().isOverdue(stage, at: now.addingTimeInterval(TimeSpan.days(1))))
    }

    // MARK: The horizon and the retry bound

    func testTheSchedulingHorizonExcludesTheFarFuture() {
        let policy = SupportCatchUpPolicy(schedulingHorizon: TimeSpan.days(7))
        XCTAssertTrue(policy.isWithinHorizon(now.addingTimeInterval(TimeSpan.days(6)), from: now))
        XCTAssertFalse(policy.isWithinHorizon(now.addingTimeInterval(TimeSpan.days(8)), from: now))
    }

    /// Section 62. Permission the user switched off is not a transient error, and
    /// an app that retries it on every launch is a battery bug that also lies
    /// about whether the reminder will fire.
    func testAPermanentlyUnavailableStageIsNeverRetried() {
        let policy = SupportCatchUpPolicy()
        var delivery = StageDelivery()
        delivery.failed(at: now, reason: "notifications permission denied", isPermanent: true)

        XCTAssertEqual(delivery.state, .unavailable)
        XCTAssertFalse(policy.permitsAnotherAttempt(delivery))
    }

    /// Section 63. Transient failures are retried, but not forever.
    func testTransientFailuresAreRetriedUpToTheBound() {
        let policy = SupportCatchUpPolicy(maximumSchedulingAttempts: 3)
        var delivery = StageDelivery()

        for attempt in 1...3 {
            XCTAssertTrue(policy.permitsAnotherAttempt(delivery), "attempt \(attempt) should be allowed")
            delivery.failed(at: now, reason: "the system refused the request", isPermanent: false)
        }

        XCTAssertEqual(delivery.attempts, 3)
        XCTAssertEqual(delivery.state, .failed)
        XCTAssertFalse(policy.permitsAnotherAttempt(delivery))
    }

    /// A success clears the failure and stops the retry counting mattering.
    func testASuccessfulAttemptRecordsTheRevisionAndClearsTheReason() {
        var delivery = StageDelivery()
        delivery.failed(at: now, reason: "the system refused the request", isPermanent: false)
        delivery.succeeded(at: now.addingTimeInterval(60), revision: 4)

        XCTAssertEqual(delivery.state, .scheduled)
        XCTAssertTrue(delivery.state.isLive)
        XCTAssertNil(delivery.failureReason)
        XCTAssertEqual(delivery.scheduledRevision, 4)
    }

    /// The failure reason reaches logs and the diagnostics screen. Section 120:
    /// whatever the OS said about the request must not carry the user's own text
    /// into either of them unbounded.
    func testTheFailureReasonIsTruncated() {
        var delivery = StageDelivery()
        delivery.failed(at: now, reason: String(repeating: "x", count: 500), isPermanent: false)
        XCTAssertEqual(delivery.failureReason?.count, 120)
    }

    /// Withdrawing forgets the revision, so the stage is not mistaken for one
    /// iOS is still holding.
    func testWithdrawalReturnsAStageToPlanned() {
        var delivery = StageDelivery()
        delivery.succeeded(at: now, revision: 2)
        delivery.withdrawn()

        XCTAssertEqual(delivery.state, .planned)
        XCTAssertNil(delivery.scheduledRevision)
        XCTAssertTrue(delivery.state.isRetryable)
    }

    /// Answering a stage withdraws its delivery without a separate call. A
    /// dismissed stage is not one iOS should still be holding a request for.
    func testResolvingAStageWithdrawsItsDelivery() {
        var stage = pendingStage(due: now)
        stage.delivery.succeeded(at: now, revision: 1)
        XCTAssertTrue(stage.wantsDelivery)

        stage.transition(to: .dismissed, at: now)

        XCTAssertEqual(stage.delivery.state, .planned)
        XCTAssertFalse(stage.wantsDelivery)
    }

    /// A stage that cannot be delivered at all is not offered to the scheduler
    /// again, which is what stops the permission-denied case looping.
    func testAnUnavailableStageDoesNotWantDelivery() {
        var stage = pendingStage(due: now)
        stage.delivery.failed(at: now, reason: "notifications permission denied", isPermanent: true)
        XCTAssertFalse(stage.wantsDelivery)
    }

    // MARK: Compression

    /// Sections 69 to 71, and the reason this policy exists.
    ///
    /// A two-hourly follow-up ladder left running for a week is dozens of
    /// theoretically-missed stages. All of them really were missed and the plan
    /// says so — but the user gets *one* reminder, not dozens, because arriving
    /// to a screenful of notifications is precisely the overwhelm this app is
    /// meant to prevent.
    func testALongAbsenceIsRecordedInFullAndSchedulesOneReminder() {
        let policy = SupportCatchUpPolicy(maximumHistoricalStagesPerTask: 3)
        var fixture = makeFixture()
        fixture.plan.stages = (1...12).map { hour in
            pendingStage(due: now.addingTimeInterval(TimeSpan.hours(Double(hour))))
        }

        let aWeekLater = now.addingTimeInterval(TimeSpan.days(7))
        let recovered = FollowUpCoordinator().reconcile(
            task: fixture.task,
            plan: fixture.plan,
            context: context(at: aWeekLater),
            policy: policy
        )

        // Every one of them is acknowledged as missed…
        XCTAssertEqual(recovered.catchUp.missedStages.count, 12)
        XCTAssertTrue(recovered.catchUp.wasCompressed)
        XCTAssertEqual(recovered.catchUp.appliedStages.count, 3)
        XCTAssertEqual(recovered.catchUp.absorbedCount, 9)

        // …and none of them is still pending, so nothing from the backlog can
        // reach the notification centre on the next pass either.
        let historical = recovered.plan.stages.prefix(12)
        XCTAssertTrue(historical.allSatisfy { !$0.state.isPending })

        // Exactly one intervention, and it is a real one.
        XCTAssertEqual(recovered.schedule.count, 1)
        XCTAssertEqual(recovered.plan.pendingStages.count, 1)
    }

    /// Section 72. Elapsed time is evidence that support is not working, which is
    /// worth escalating for — but a week of silence must not jump straight to an
    /// alarm, because nothing the user *did* justified it.
    func testEscalationClimbsByAtMostOneStepPerPass() {
        let policy = SupportCatchUpPolicy(maximumEscalationStepsPerPass: 1)
        var fixture = makeFixture(importance: .high)
        fixture.plan.stages = (1...20).map { hour in
            var stage = pendingStage(due: now.addingTimeInterval(TimeSpan.hours(Double(hour))))
            stage.escalation = .gentle
            return stage
        }

        let recovered = FollowUpCoordinator().reconcile(
            task: fixture.task,
            plan: fixture.plan,
            context: context(at: now.addingTimeInterval(TimeSpan.days(7))),
            policy: policy
        )

        let scheduled = recovered.schedule.first
        XCTAssertNotNil(scheduled)
        XCTAssertLessThanOrEqual(scheduled?.escalation ?? .alarm, .standard)
        XCTAssertNotEqual(scheduled?.channel, .alarm)

        // What was persisted agrees with what was scheduled. Clamping only the
        // outgoing request would leave the plan claiming a level the user never
        // actually got.
        for stage in recovered.plan.pendingStages {
            XCTAssertLessThanOrEqual(stage.escalation, .standard)
        }
    }

    func testTheClampHoldsALevelWithinTheAllowedNumberOfSteps() {
        XCTAssertEqual(FollowUpCoordinator.clamp(.alarm, from: .gentle, steps: 1), .standard)
        XCTAssertEqual(FollowUpCoordinator.clamp(.alarm, from: .standard, steps: 1), .insistent)
        XCTAssertEqual(FollowUpCoordinator.clamp(.alarm, from: .insistent, steps: 1), .alarm)
        // Already below the ceiling: left exactly as it is.
        XCTAssertEqual(FollowUpCoordinator.clamp(.gentle, from: .gentle, steps: 1), .gentle)
        // No escalation permitted at all.
        XCTAssertEqual(FollowUpCoordinator.clamp(.alarm, from: .gentle, steps: 0), .gentle)
    }

    /// However many rounds a compression pass runs internally, it leaves
    /// exactly one reminder waiting.
    ///
    /// The rounds are the pass's own working out, not reminders. Any stage they
    /// created and then superseded is withdrawn here rather than left pending —
    /// otherwise the scheduler would hand every one of them to iOS and the
    /// compression would have been cosmetic.
    func testACatchUpPassLeavesExactlyOneStagePending() {
        var fixture = makeFixture()
        fixture.plan.stages = (1...8).map { hour in
            pendingStage(due: now.addingTimeInterval(TimeSpan.hours(Double(hour))))
        }

        let recovered = FollowUpCoordinator().reconcile(
            task: fixture.task,
            plan: fixture.plan,
            context: context(at: now.addingTimeInterval(TimeSpan.days(2)))
        )

        XCTAssertEqual(recovered.plan.pendingStages.count, 1)
        XCTAssertEqual(recovered.schedule.count, 1)
        XCTAssertEqual(recovered.schedule.first?.stageID, recovered.plan.pendingStages.first?.id)

        // The withdrawals are reported, so the caller can take them off the OS
        // too rather than leaving orphaned requests behind.
        for stage in recovered.cancel {
            XCTAssertEqual(recovered.plan.stage(id: stage.id)?.state, .cancelled)
        }
    }

    /// The trap this pass fell into once, kept as a test.
    ///
    /// Every round inside one pass computes its delay from the same
    /// `context.now`, and the planner declines to add a follow-up when an
    /// equivalent one is already waiting — so the second and third rounds
    /// routinely produce *nothing*. Reading the result off the last round would
    /// see an empty schedule, conclude there was nothing to keep, and cancel
    /// the one real follow-up the pass had produced. Which would leave a task
    /// that missed a dozen reminders with no reminder at all.
    func testARoundThatSchedulesNothingDoesNotDiscardTheOneThatDid() {
        var fixture = makeFixture()
        fixture.plan.stages = (1...5).map { hour in
            pendingStage(due: now.addingTimeInterval(TimeSpan.hours(Double(hour))))
        }

        let recovered = FollowUpCoordinator().reconcile(
            task: fixture.task,
            plan: fixture.plan,
            context: context(at: now.addingTimeInterval(TimeSpan.days(1)))
        )

        XCTAssertFalse(
            recovered.schedule.isEmpty,
            "a task with a backlog of missed reminders must still be chased"
        )
        XCTAssertEqual(recovered.plan.pendingStages.count, 1)
    }

    /// Running the same pass twice changes nothing the second time. This is what
    /// makes reconciling on every foreground safe (section 48).
    func testASecondPassOverTheSameBacklogDoesNothing() {
        var fixture = makeFixture()
        fixture.plan.stages = (1...6).map { hour in
            pendingStage(due: now.addingTimeInterval(TimeSpan.hours(Double(hour))))
        }

        let coordinator = FollowUpCoordinator()
        let later = now.addingTimeInterval(TimeSpan.days(1))
        let first = coordinator.reconcile(task: fixture.task, plan: fixture.plan, context: context(at: later))
        let second = coordinator.reconcile(task: first.task, plan: first.plan, context: context(at: later))

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertTrue(second.schedule.isEmpty)
        XCTAssertEqual(second.plan.pendingStages.count, first.plan.pendingStages.count)
    }

    /// Section 17: one change to the plan, one bump. The revision is what a
    /// notification callback is checked against, so a pass that changed the plan
    /// without moving it would leave stale callbacks looking current.
    func testACatchUpPassMovesThePlanRevision() {
        var fixture = makeFixture()
        fixture.plan.stages = [pendingStage(due: now)]
        let before = fixture.plan.revision

        let recovered = FollowUpCoordinator().reconcile(
            task: fixture.task,
            plan: fixture.plan,
            context: context(at: now.addingTimeInterval(TimeSpan.hours(3)))
        )

        XCTAssertGreaterThan(recovered.plan.revision, before)
    }

    // MARK: Fixtures

    private func pendingStage(due: Date) -> ReminderStage {
        ReminderStage(
            kind: .followUp,
            offset: .absolute(due),
            message: "Still open",
            scheduledFor: due
        )
    }

    private struct Fixture {
        var task: TaskItem
        var plan: ReminderPlan
    }

    private func makeFixture(importance: Importance = .normal) -> Fixture {
        let task = TaskItem(
            title: "Pay the electricity bill",
            status: .reminded,
            importance: importance,
            createdAt: now.addingTimeInterval(-TimeSpan.hours(6))
        )
        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(task.id),
                title: task.title,
                anchor: .unscheduled,
                importance: importance
            ),
            stages: [],
            createdAt: now.addingTimeInterval(-TimeSpan.hours(6)),
            generatedBy: "test"
        )
        return Fixture(task: task, plan: plan)
    }
}
