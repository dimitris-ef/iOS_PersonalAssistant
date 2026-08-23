import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import MockPlatform
import XCTest

/// The lifecycle wired to real repositories and the mock platform layer.
///
/// `FollowUpCoordinatorTests` covers the policy; this covers the plumbing —
/// that decisions are persisted, that the platform layer is asked to schedule
/// and cancel, and that a repeated callback does not double either.
final class FollowUpServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeService(
        repositories: AssistantRepositories,
        services: PlatformServices
    ) -> FollowUpService {
        FollowUpService(
            repositories: repositories,
            services: services,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    // MARK: Dismissal

    func testDismissalPersistsTheFollowUpAndSchedulesIt() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let service = makeService(repositories: repositories, services: services)
        let (task, plan) = try await seed(into: repositories)

        let result = try await service.handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id
        )

        XCTAssertTrue(result.didChange)
        XCTAssertNotEqual(result.task.status, .completed)
        XCTAssertNotNil(result.nextReminder)

        // Persisted, not just returned.
        let storedTask = try await repositories.tasks.task(id: task.id)
        let storedPlan = try await repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(storedTask?.status, .needsFollowUp)
        XCTAssertEqual(storedPlan?.pendingStages.count, 1)

        // And the platform layer was actually asked — through whichever
        // service the escalation chose. This task is `.high`, and
        // `TaskStatusMachine.escalated(_:plan:)` takes a dismissed
        // high-importance task straight to `.alarm`, so the follow-up arrives
        // as an alarm rather than a notification. Asserting on notifications
        // specifically was this test assuming the gentler path.
        let scheduled = try XCTUnwrap(result.nextReminder)
        XCTAssertEqual(scheduled.channel, .alarm)
        try await assertOnePlatformRequest(for: scheduled, task: task, in: services)
    }

    /// Callbacks get retried. Two deliveries must not become two reminders — at
    /// the domain level *or* at the OS level.
    func testProcessingTheSameDismissalTwiceSchedulesOneNotification() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let service = makeService(repositories: repositories, services: services)
        let (task, plan) = try await seed(into: repositories)

        _ = try await service.handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id
        )
        let second = try await service.handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id
        )

        XCTAssertFalse(second.didChange)
        XCTAssertNil(second.nextReminder)

        let storedPlan = try await repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(storedPlan?.pendingStages.count, 1)

        // One OS-level request, not two — the point of the test. Counted
        // across both services, because a high-importance dismissal escalates
        // to an alarm.
        let requests = try await platformRequestCount(in: services)
        XCTAssertEqual(requests, 1)
    }

    // MARK: Snooze

    func testSnoozeReschedulesRatherThanDuplicating() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let service = makeService(repositories: repositories, services: services)
        let (task, plan) = try await seed(into: repositories)

        let until = now.addingTimeInterval(TimeSpan.minutes(30))
        let result = try await service.handle(
            outcome: .snoozed(until: until),
            forTask: task.id,
            stageID: plan.stages[0].id
        )

        XCTAssertEqual(result.nextReminder?.fireDate, until)

        let storedTask = try await repositories.tasks.task(id: task.id)
        let storedPlan = try await repositories.reminderPlans.plan(id: plan.id)
        XCTAssertNotEqual(storedTask?.status, .completed)
        XCTAssertEqual(storedTask?.snoozeCount, 1)
        XCTAssertEqual(storedPlan?.pendingStages.count, 1)

        let pending = try await services.notifications.pendingNotifications()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.fireDate, until)
    }

    // MARK: Reconciliation

    /// A reminder that came due while the app was closed.
    func testReconciliationCatchesUpOnAnOverdueReminder() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let (task, plan) = try await seed(into: repositories)

        // The clock has moved on an hour past the reminder.
        let later = now.addingTimeInterval(TimeSpan.hours(1))
        let service = FollowUpService(
            repositories: repositories,
            services: services,
            dateProvider: FixedDateProvider(now: later)
        )

        var pendingPlan = plan
        pendingPlan.stages[0].state = .pending
        try await repositories.reminderPlans.save(pendingPlan)

        let result = try await service.reconcile(task: task.id)

        let recovered = try XCTUnwrap(result)
        XCTAssertEqual(recovered.task.status, .needsFollowUp)

        let storedPlan = try await repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(storedPlan?.stage(id: plan.stages[0].id)?.state, .missed)
        XCTAssertEqual(storedPlan?.pendingStages.count, 1)

        // Running it again finds nothing new to do.
        let again = try await service.reconcile(task: task.id)
        XCTAssertNil(again)
    }

    // MARK: Resolution

    func testCompletionWithdrawsTheWaitingReminder() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let service = makeService(repositories: repositories, services: services)
        let (task, plan) = try await seed(into: repositories)

        // Dismiss first, so there is a real pending request to withdraw.
        _ = try await service.handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id
        )
        let beforeCompletion = try await platformRequestCount(in: services)
        XCTAssertEqual(beforeCompletion, 1)

        _ = try await service.handle(outcome: .completed, forTask: task.id)

        let storedTask = try await repositories.tasks.task(id: task.id)
        let storedPlan = try await repositories.reminderPlans.plan(id: plan.id)

        XCTAssertEqual(storedTask?.status, .completed)
        XCTAssertTrue(storedPlan?.pendingStages.isEmpty ?? false)
        let afterCompletion = try await platformRequestCount(in: services)
        XCTAssertEqual(
            afterCompletion,
            0,
            "finishing a task must withdraw the reminders that were still waiting"
        )
    }

    /// The stale 7:30 callback after a 7:20 completion.
    func testAStaleCallbackAfterCompletionSchedulesNothing() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let service = makeService(repositories: repositories, services: services)
        let (task, plan) = try await seed(into: repositories)

        _ = try await service.handle(outcome: .completed, forTask: task.id)
        let stale = try await service.handle(
            outcome: .missed,
            forTask: task.id,
            stageID: plan.stages[0].id
        )

        XCTAssertFalse(stale.didChange)
        XCTAssertEqual(stale.task.status, .completed)

        let pending = try await services.notifications.pendingNotifications()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCompletingATaskWithNoPlanStillCompletesIt() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let service = makeService(repositories: repositories, services: services)

        let task = TaskItem(title: "Buy milk", createdAt: now)
        try await repositories.tasks.save(task)

        let result = try await service.handle(outcome: .completed, forTask: task.id)

        XCTAssertEqual(result.task.status, .completed)
        let stored = try await repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.status, .completed)
    }

    // MARK: Fixtures

    /// Outstanding OS-level requests across every channel.
    ///
    /// Counted across both services on purpose. Which one a follow-up lands in
    /// is an escalation decision — a `.high` task goes straight to an alarm —
    /// and a test that counted only notifications would silently pass while
    /// the assistant scheduled nothing, or fail while it did the right thing.
    private func platformRequestCount(in services: PlatformServices) async throws -> Int {
        let notifications = try await services.notifications.pendingNotifications()
        let alarms = try await services.alarms.scheduledAlarms()
        return notifications.count + alarms.count
    }

    /// Exactly one request, in the channel the service said it used, for this
    /// task — and carrying the stage id, which is what makes it cancellable.
    private func assertOnePlatformRequest(
        for reminder: ScheduledReminder,
        task: TaskItem,
        in services: PlatformServices,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let total = try await platformRequestCount(in: services)
        XCTAssertEqual(total, 1, file: file, line: line)

        switch reminder.channel {
        case .alarm:
            let alarms = try await services.alarms.scheduledAlarms()
            XCTAssertEqual(alarms.first?.relatedTaskID, task.id, file: file, line: line)
            XCTAssertEqual(
                alarms.first?.id.rawValue, reminder.stageID.rawValue,
                "the stage id is the request id — cancelling depends on it",
                file: file, line: line
            )
        case .notification, .reminderList:
            let pending = try await services.notifications.pendingNotifications()
            XCTAssertEqual(pending.first?.relatedTaskID, task.id, file: file, line: line)
            XCTAssertEqual(
                pending.first?.id.rawValue, reminder.stageID.rawValue,
                "the stage id is the request id — cancelling depends on it",
                file: file, line: line
            )
        }
    }

    private func seed(
        into repositories: AssistantRepositories
    ) async throws -> (TaskItem, ReminderPlan) {
        var task = TaskItem(
            title: "Pay the electricity bill",
            status: .reminded,
            importance: .high,
            deadline: now.addingTimeInterval(TimeSpan.hours(2)),
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
                anchor: .deadline(now.addingTimeInterval(TimeSpan.hours(2))),
                importance: .high
            ),
            stages: [stage],
            createdAt: now.addingTimeInterval(-TimeSpan.hours(6)),
            generatedBy: "test"
        )

        task.reminderPlanID = plan.id
        try await repositories.reminderPlans.save(plan)
        try await repositories.tasks.save(task)
        return (task, plan)
    }
}
