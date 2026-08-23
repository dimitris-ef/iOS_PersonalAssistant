import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import Foundation
import MockPlatform
import XCTest

@testable import AssistantCore

/// The app disappeared, and then it came back.
///
/// Everything in this file is the same story told from a different angle: the
/// process was not running while reminders came due, and the only evidence of
/// what should have happened is what was written to disk before it stopped.
/// There is no timer anywhere here, nothing sleeps, and no test waits on a real
/// notification — the clock is injected and iOS is a mock that records requests.
final class SupportReconciliationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: Relaunch

    /// Section 95. Reminder scheduled, app terminated, time passes, app
    /// relaunched — and the assistant picks up where it left off.
    ///
    /// A delivered-and-ignored notification produces no callback at all: iOS has
    /// nothing to report, because nothing happened. This sweep is the only thing
    /// in the entire system that ever notices.
    func testARelaunchAfterAMissedReminderRecoversIt() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seedOverdueReminder(at: now)

        let service = harness.service(at: now.addingTimeInterval(TimeSpan.hours(3)))
        let report = try await service.reconcile(trigger: .launch)

        XCTAssertEqual(report.missedStages, 1)
        XCTAssertEqual(report.followUpsGenerated, 1)
        XCTAssertGreaterThan(report.scheduled, 0)

        // The domain is what changed. The notification is a consequence.
        let storedTask = try await harness.repositories.tasks.task(id: task.id)
        let storedPlan = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(storedTask?.status, .needsFollowUp)
        XCTAssertNotEqual(storedTask?.status, .completed)
        XCTAssertEqual(storedPlan?.stage(id: plan.stages[0].id)?.state, .missed)
        XCTAssertEqual(storedPlan?.pendingStages.count, 1)

        // And iOS is now holding the replacement.
        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 1)
    }

    /// Section 96. Launching three times must not produce three follow-ups, or
    /// three notifications, or an escalation level that climbed for no reason
    /// other than the user opening their phone.
    func testRepeatedRelaunchesChangeNothingFurther() async throws {
        let harness = Harness()
        _ = try await harness.seedOverdueReminder(at: now)

        let service = harness.service(at: now.addingTimeInterval(TimeSpan.hours(3)))
        let first = try await service.reconcile(trigger: .launch)
        let second = try await service.reconcile(trigger: .foreground)
        let third = try await service.reconcile(trigger: .foreground)

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertFalse(third.didChange)

        // Section 28: a pass over an unchanged store makes no platform calls at
        // all. That is what makes reconciling on every foreground affordable.
        XCTAssertEqual(second.scheduled, 0)
        XCTAssertEqual(second.cancelled, 0)
        XCTAssertEqual(second.unchanged, 1)

        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 1)
    }

    /// Section 97. A store already in the right state is left completely alone —
    /// the diff, not `removeAllPendingNotificationRequests()`.
    func testAnAlreadyCorrectScheduleIsNotRewritten() async throws {
        let harness = Harness()
        _ = try await harness.seedFutureReminder(at: now.addingTimeInterval(TimeSpan.hours(4)))

        let service = harness.service(at: now)
        let first = try await service.reconcile(trigger: .launch)
        XCTAssertEqual(first.scheduled, 1)

        let before = await harness.notifications.scheduleAttempts.count
        let second = try await service.reconcile(trigger: .foreground)
        let after = await harness.notifications.scheduleAttempts.count

        XCTAssertEqual(second.unchanged, 1)
        XCTAssertEqual(second.scheduled, 0)
        XCTAssertEqual(before, after, "an unchanged request must not be torn down and re-added")
    }

    /// Section 100. Completing a task withdraws what iOS is still holding — and
    /// keeps it withdrawn when the next pass runs.
    func testCompletingATaskWithdrawsItsPendingRequests() async throws {
        let harness = Harness()
        let (task, _) = try await harness.seedFutureReminder(at: now.addingTimeInterval(TimeSpan.hours(4)))

        let service = harness.service(at: now)
        _ = try await service.reconcile(trigger: .launch)
        let beforeCompletion = try await harness.platformRequestCount()
        XCTAssertEqual(beforeCompletion, 1)

        _ = try await harness.followUp(at: now).handle(outcome: .completed, forTask: task.id)

        let afterCompletion = try await harness.platformRequestCount()
        XCTAssertEqual(afterCompletion, 0)

        // Section 57: the completed task wins, permanently. A later pass must
        // not read the plan and put the reminder back.
        let later = try await harness.service(at: now.addingTimeInterval(TimeSpan.hours(1)))
            .reconcile(trigger: .foreground)
        XCTAssertEqual(later.scheduled, 0)
        let stillNone = try await harness.platformRequestCount()
        XCTAssertEqual(stillNone, 0)
    }

    /// Section 58 and 56. An OS request with no live domain stage behind it is
    /// withdrawn: the database decides, never the notification centre.
    func testARequestWithNoDomainStageBehindItIsWithdrawn() async throws {
        let harness = Harness()
        let orphan = ReminderStage.ID()
        _ = try await harness.notifications.schedule(
            NotificationRequest(
                id: NotificationRequest.ID(orphan.rawValue),
                title: "A reminder for something that no longer exists",
                body: "",
                fireDate: now.addingTimeInterval(TimeSpan.hours(2)),
                stageID: orphan,
                planRevision: 1
            )
        )

        let report = try await harness.service(at: now).reconcile(trigger: .launch)

        XCTAssertEqual(report.cancelled, 1)
        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 0)
    }

    // MARK: Scheduling failures

    /// Section 102 and 62. Notifications are switched off. The reminder still
    /// exists in the domain — the app has not forgotten the user's task — and
    /// the failure is recorded truthfully rather than retried forever.
    func testPermissionDeniedIsRecordedAndNotRetriedForever() async throws {
        let harness = Harness()
        let (_, plan) = try await harness.seedFutureReminder(
            at: now.addingTimeInterval(TimeSpan.hours(4))
        )
        await harness.notifications.setBehaviour(.permissionDenied)

        let service = harness.service(at: now)
        let first = try await service.reconcile(trigger: .launch)

        XCTAssertEqual(first.schedulingFailures, 1)
        XCTAssertTrue(first.deliveryUnavailable)

        // The domain reminder survives. Section 61: a scheduling failure is not
        // permission to forget the task.
        let stored = try await harness.repositories.reminderPlans.plan(id: plan.id)
        let stage = try XCTUnwrap(stored?.stages.first)
        XCTAssertTrue(stage.state.isPending)
        XCTAssertEqual(stage.delivery.state, .unavailable)
        XCTAssertNotNil(stage.delivery.failureReason)

        // And it is not attempted again. An app that retries a decision the user
        // made, on every launch, is a battery bug that also lies about whether
        // the reminder will fire.
        let attemptsAfterFirst = await harness.notifications.scheduleAttempts.count
        let second = try await service.reconcile(trigger: .foreground)
        let attemptsAfterSecond = await harness.notifications.scheduleAttempts.count

        XCTAssertEqual(second.schedulingFailures, 0)
        XCTAssertEqual(attemptsAfterFirst, attemptsAfterSecond)
    }

    /// Section 103 and 63. A transient refusal is retried on the next pass, and
    /// the retry is a replacement rather than a second reminder.
    func testATransientSchedulingFailureIsRetriedOnTheNextPass() async throws {
        let harness = Harness()
        let (_, plan) = try await harness.seedFutureReminder(
            at: now.addingTimeInterval(TimeSpan.hours(4))
        )
        await harness.notifications.setBehaviour(.failTransiently(count: 1))

        let service = harness.service(at: now)
        let first = try await service.reconcile(trigger: .launch)
        XCTAssertEqual(first.schedulingFailures, 1)
        XCTAssertFalse(first.deliveryUnavailable)

        let afterFailure = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(afterFailure?.stages.first?.delivery.state, .failed)

        let second = try await service.reconcile(trigger: .foreground)
        XCTAssertEqual(second.scheduled, 1)
        XCTAssertEqual(second.schedulingFailures, 0)

        let afterRetry = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(afterRetry?.stages.first?.delivery.state, .scheduled)

        // One reminder, not two. The stage id is the request id, so the retry
        // replaced rather than duplicated.
        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 1)
    }

    /// Recording *how* a stage was delivered is not a change to the plan, so the
    /// revision must not move — or every notification in flight would look stale
    /// the instant after it was scheduled.
    func testSchedulingDoesNotBumpThePlanRevision() async throws {
        let harness = Harness()
        let (_, plan) = try await harness.seedFutureReminder(
            at: now.addingTimeInterval(TimeSpan.hours(4))
        )

        _ = try await harness.service(at: now).reconcile(trigger: .launch)

        let stored = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(stored?.revision, plan.revision)
        XCTAssertEqual(stored?.stages.first?.delivery.scheduledRevision, plan.revision)
    }

    // MARK: A long absence

    /// Section 104. A week away, with a follow-up ladder that kept theoretically
    /// firing the whole time. The user gets one reminder, not a screenful.
    func testAWeekAwayProducesOneReminderNotABacklog() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seedBacklog(count: 10, from: now)

        let service = harness.service(at: now.addingTimeInterval(TimeSpan.days(7)))
        let report = try await service.reconcile(trigger: .launch)

        XCTAssertEqual(report.missedStages, 10)
        XCTAssertGreaterThan(report.absorbedStages, 0)

        // Every one of them is on the record…
        let storedPlan = try await harness.repositories.reminderPlans.plan(id: plan.id)
        let historical = storedPlan?.stages.prefix(10) ?? []
        XCTAssertTrue(historical.allSatisfy { $0.state == .missed })

        // …and exactly one of them is in the notification centre.
        XCTAssertEqual(storedPlan?.pendingStages.count, 1)
        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 1)

        let storedTask = try await harness.repositories.tasks.task(id: task.id)
        XCTAssertNotEqual(storedTask?.status, .completed)
    }

    /// Sections 87 to 90. A stage months out is left in the plan and not handed
    /// to iOS, so the pending queue holds what is imminent rather than
    /// everything the assistant has ever decided.
    func testStagesBeyondTheHorizonAreNotScheduledYet() async throws {
        let harness = Harness()
        _ = try await harness.seedFutureReminder(at: now.addingTimeInterval(TimeSpan.days(60)))

        let report = try await harness.service(at: now).reconcile(trigger: .launch)

        XCTAssertEqual(report.scheduled, 0)
        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 0)
    }

    // MARK: Concurrency

    /// Sections 83, 84 and 111. The app becomes active at the same moment a
    /// background refresh fires. Two passes over the same overdue stage would
    /// both decide it was missed and both generate a follow-up.
    func testOverlappingTriggersRunAsOnePass() async throws {
        let harness = Harness()
        _ = try await harness.seedOverdueReminder(at: now)
        let service = harness.service(at: now.addingTimeInterval(TimeSpan.hours(3)))

        async let foreground = service.reconcile(trigger: .foreground)
        async let background = service.reconcile(trigger: .backgroundRefresh)
        let (a, b) = try await (foreground, background)

        // The second caller awaited the first rather than being turned away —
        // being told "someone else is doing it" would be useless to a caller
        // that needs the state settled before it draws a screen.
        XCTAssertEqual(a.passID, b.passID)
        XCTAssertEqual(a.missedStages, 1)

        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 1)
    }

    /// Section 110. Cancelling when nothing is running is a no-op, and a pass
    /// after a cancellation still recovers everything — the work is resumable by
    /// construction, because every step commits before the next begins.
    func testCancellingIsSafeAndTheNextPassStillRecovers() async throws {
        let harness = Harness()
        _ = try await harness.seedOverdueReminder(at: now)
        let service = harness.service(at: now.addingTimeInterval(TimeSpan.hours(3)))

        await service.cancel()
        let report = try await service.reconcile(trigger: .backgroundRefresh)

        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(report.missedStages, 1)
        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 1)
    }

    // MARK: Routines

    /// Section 105 and 34. A recurring responsibility whose moment passed while
    /// the app was closed has to *exist as a task* before anything can notice it
    /// was missed — which is why routines run first in the pass.
    func testRoutineOccurrencesAreRecoveredDuringThePass() async throws {
        let harness = Harness()
        let routine = Routine(
            title: "Put the bins out",
            recurrence: RecurrenceRule(
                frequency: .daily,
                timeOfDay: TimeOfDay(hour: 9),
                startDate: now.addingTimeInterval(-TimeSpan.days(3))
            ),
            createdAt: now.addingTimeInterval(-TimeSpan.days(3))
        )
        try await harness.repositories.routines.save(routine)

        let report = try await harness.service(at: now).reconcile(trigger: .launch)

        XCTAssertGreaterThan(
            report.routineOccurrencesCreated + report.routineOccurrencesRecovered,
            0,
            "a routine whose moment passed while the app was closed must be materialised"
        )
        let generated = try await harness.repositories.tasks.tasks(
            matching: TaskFilter(routineID: routine.id)
        )
        XCTAssertFalse(generated.isEmpty)
    }

    // MARK: Boundedness

    /// Section 86. A background refresh has seconds, not minutes. A store with a
    /// thousand historical tasks must not be walked in full before the app can
    /// say anything.
    func testAPassIsBoundedByTheTaskLimit() async throws {
        let harness = Harness()
        for index in 0..<12 {
            try await harness.repositories.tasks.save(
                TaskItem(title: "Task \(index)", status: .notStarted, createdAt: now)
            )
        }

        let service = harness.service(
            at: now,
            policy: SupportCatchUpPolicy(maximumTasksPerPass: 5)
        )
        let report = try await service.reconcile(trigger: .backgroundRefresh)

        XCTAssertEqual(report.tasksEvaluated, 5)
        XCTAssertTrue(report.wasTruncated)
    }

    // MARK: What it must never do

    /// Section 44, and a hard requirement: **routine background reconciliation
    /// must not call an AI provider.** Not the remote one, not Apple Foundation
    /// Models, not a local model.
    ///
    /// Asserted against a provider that records every request it receives, so
    /// this fails loudly if anything on the reconciliation path ever acquires a
    /// dependency on inference. The structural guarantee is stronger still —
    /// `SupportReconciliationService` takes repositories, platform services, a
    /// clock and pure policies, and has no registry in scope to call.
    func testReconciliationNeverCallsAProvider() async throws {
        let harness = Harness()
        _ = try await harness.seedOverdueReminder(at: now)

        let provider = StubAIProvider(id: "test.must.not.be.called", text: "should never happen")
        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [provider]),
            repositories: harness.repositories,
            services: harness.services,
            dateProvider: FixedDateProvider(now: now.addingTimeInterval(TimeSpan.hours(3)))
        )

        let report = try await engine.reconciliation.reconcile(trigger: .backgroundRefresh)

        XCTAssertEqual(report.missedStages, 1)
        XCTAssertTrue(
            provider.receivedRequests.isEmpty,
            "reconciliation must work with no model available at all"
        )
    }

    /// Section 112 and 45. The same absence, reconciled under two entirely
    /// different providers, produces the same support. Recovery is domain logic;
    /// which model answers the user has nothing to do with it.
    func testRecoveryIsIdenticalUnderDifferentProviders() async throws {
        func recover(with provider: StubAIProvider) async throws -> (Int, TaskStatus?) {
            let harness = Harness()
            let (task, _) = try await harness.seedOverdueReminder(at: now)
            let engine = AssistantEngine(
                providers: AIProviderRegistry(providers: [provider]),
                repositories: harness.repositories,
                services: harness.services,
                dateProvider: FixedDateProvider(now: now.addingTimeInterval(TimeSpan.hours(3)))
            )
            let report = try await engine.reconciliation.reconcile(trigger: .launch)
            let stored = try await harness.repositories.tasks.task(id: task.id)
            return (report.missedStages, stored?.status)
        }

        let viaLocal = try await recover(with: StubAIProvider(id: "local.stub"))
        let viaRemote = try await recover(with: StubAIProvider(id: "remote.stub"))

        XCTAssertEqual(viaLocal.0, viaRemote.0)
        XCTAssertEqual(viaLocal.1, viaRemote.1)
        XCTAssertEqual(viaLocal.1, .needsFollowUp)
    }

    /// Section 120. The report a pass hands to a logger is counts and
    /// identifiers. A log line naming what somebody is being reminded about is
    /// the most private thing this app could emit.
    func testTheReportSummaryCarriesNoTaskText() async throws {
        let harness = Harness()
        _ = try await harness.seedOverdueReminder(at: now, title: "Collect prescription")

        let recorder = RecordingReconciliationLogger()
        let service = harness.service(
            at: now.addingTimeInterval(TimeSpan.hours(3)),
            logger: recorder
        )
        _ = try await service.reconcile(trigger: .launch)

        let summaries = recorder.summaries
        XCTAssertEqual(summaries.count, 1)
        for summary in summaries {
            XCTAssertFalse(summary.contains("Collect prescription"))
            XCTAssertFalse(summary.lowercased().contains("prescription"))
        }
    }

    // MARK: Harness

    /// Repositories, mock platform services, and the concrete mocks kept to hand
    /// so a test can make iOS refuse.
    private struct Harness {
        let repositories: AssistantRepositories
        let notifications: MockNotificationService
        let alarms: MockAlarmService
        let services: PlatformServices

        init() {
            let notifications = MockNotificationService()
            let alarms = MockAlarmService()
            self.repositories = .ephemeral()
            self.notifications = notifications
            self.alarms = alarms
            self.services = PlatformServices(
                calendar: MockCalendarService(),
                reminders: MockReminderService(),
                notifications: notifications,
                alarms: alarms,
                permissions: MockPermissionService()
            )
        }

        func service(
            at date: Date,
            policy: SupportCatchUpPolicy = .default,
            logger: (any ReconciliationLogger)? = nil
        ) -> SupportReconciliationService {
            let clock = FixedDateProvider(now: date)
            return SupportReconciliationService(
                repositories: repositories,
                services: services,
                routines: RoutineService(
                    repositories: repositories,
                    services: services,
                    dateProvider: clock
                ),
                dateProvider: clock,
                policy: policy,
                logger: logger
            )
        }

        func followUp(at date: Date) -> FollowUpService {
            FollowUpService(
                repositories: repositories,
                services: services,
                dateProvider: FixedDateProvider(now: date)
            )
        }

        func platformRequestCount() async throws -> Int {
            let pending = try await services.notifications.pendingNotifications()
            let scheduled = try await services.alarms.scheduledAlarms()
            return pending.count + scheduled.count
        }

        /// A reminder that was due at `date` and never answered.
        @discardableResult
        func seedOverdueReminder(
            at date: Date,
            title: String = "Pay the electricity bill"
        ) async throws -> (TaskItem, ReminderPlan) {
            try await seed(title: title, stages: [stage(due: date)], createdAt: date)
        }

        /// A reminder that has not fired yet.
        @discardableResult
        func seedFutureReminder(at date: Date) async throws -> (TaskItem, ReminderPlan) {
            try await seed(
                title: "Pay the electricity bill",
                stages: [stage(due: date)],
                createdAt: date.addingTimeInterval(-TimeSpan.hours(6))
            )
        }

        /// A ladder of reminders that all came due while the app was closed.
        @discardableResult
        func seedBacklog(count: Int, from date: Date) async throws -> (TaskItem, ReminderPlan) {
            try await seed(
                title: "Pay the electricity bill",
                stages: (1...count).map { step in
                    stage(due: date.addingTimeInterval(TimeSpan.hours(Double(step) * 2)))
                },
                createdAt: date
            )
        }

        private func stage(due: Date) -> ReminderStage {
            ReminderStage(
                kind: .followUp,
                offset: .absolute(due),
                // Normal importance on purpose: the high-importance ladder goes
                // straight to an alarm, and these tests are about the ordinary
                // notification path.
                escalation: .standard,
                message: "Still open",
                scheduledFor: due
            )
        }

        private func seed(
            title: String,
            stages: [ReminderStage],
            createdAt: Date
        ) async throws -> (TaskItem, ReminderPlan) {
            var task = TaskItem(
                title: title,
                status: .reminded,
                importance: .normal,
                createdAt: createdAt
            )
            let plan = ReminderPlan(
                subject: ReminderSubject(
                    reference: .task(task.id),
                    title: task.title,
                    anchor: .unscheduled,
                    importance: .normal
                ),
                stages: stages,
                createdAt: createdAt,
                generatedBy: "test"
            )
            task.reminderPlanID = plan.id
            try await repositories.reminderPlans.save(plan)
            try await repositories.tasks.save(task)
            return (task, plan)
        }
    }
}

/// Captures what a pass reported, so a test can assert on what reaches a log.
///
/// A lock rather than an actor: the protocol's methods are synchronous — a
/// logger that made its callers await would be a logger that could reorder a
/// reconciliation pass — and hopping into an actor from them would leave the
/// recording racing the assertion that reads it.
final class RecordingReconciliationLogger: ReconciliationLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSummaries: [String] = []
    private var recordedFailures: [String] = []

    var summaries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSummaries
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailures
    }

    func reconciliationFinished(
        _ report: SupportReconciliationReport,
        trigger: ReconciliationTrigger
    ) {
        lock.lock()
        defer { lock.unlock() }
        recordedSummaries.append("\(trigger.rawValue): \(report.summary)")
    }

    func reconciliationFailed(passID: UUID, stage: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedFailures.append(stage)
    }
}
