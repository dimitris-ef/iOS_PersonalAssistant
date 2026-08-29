import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import Foundation
import MockPlatform
import SystemSurfaces
import XCTest

@testable import AssistantCore

/// The join between the application and everything iOS shows outside it.
///
/// Two claims are being defended here, and both of them are about direction.
/// Domain state flows *out* into projections, and never the other way — a
/// widget cannot decide anything. And a widget's buttons flow *in* through the
/// same services the app's own buttons use, so "Done" means what it has always
/// meant rather than what a shared JSON file says.
final class SystemSurfaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Snapshots

    /// Section 96. Seed real state, build the projection, assert on exactly
    /// what it contains — and on what it does not.
    func testTheTodaySnapshotCarriesTheRankedDayAndNothingMore() async throws {
        let harness = Harness()
        let task = try await harness.seedTask(
            title: "Pay the electricity bill",
            due: now.addingTimeInterval(TimeSpan.hours(2)),
            importance: .high
        )

        let report = await harness.service(at: now).refresh()
        XCTAssertGreaterThan(report.todayItems, 0)

        let snapshot = try harness.store.read(TodaySnapshot.self)
        let row = try XCTUnwrap(snapshot.items.first { $0.taskID == task.id.rawValue })

        XCTAssertEqual(row.title, "Pay the electricity bill")
        XCTAssertEqual(row.kind, .task)
        XCTAssertFalse(row.isDone)
        XCTAssertEqual(snapshot.snapshotVersion, TodaySnapshot.currentVersion)
        XCTAssertEqual(snapshot.generatedAt, now)
    }

    /// The prioritisation is already reflected — the widget does not rank.
    /// Section 19 and section 33.
    func testTheNextTaskSnapshotReflectsTheDomainRankingAlready() async throws {
        let harness = Harness()
        _ = try await harness.seedTask(
            title: "Something later",
            due: now.addingTimeInterval(TimeSpan.hours(9)),
            importance: .low
        )
        let urgent = try await harness.seedTask(
            title: "Collect prescription",
            due: now.addingTimeInterval(TimeSpan.minutes(40)),
            importance: .critical
        )

        _ = await harness.service(at: now).refresh()

        let snapshot = try harness.store.read(TaskWidgetSnapshot.self)
        XCTAssertEqual(snapshot.task?.taskID, urgent.id.rawValue)
        XCTAssertEqual(snapshot.task?.emphasis, .upNext)
        XCTAssertEqual(snapshot.outstandingCount, 2)
        XCTAssertFalse(snapshot.isBlocked)
    }

    /// Section 113. Whatever else changes, none of this may appear in a file a
    /// widget process can read.
    func testSnapshotsContainNoCredentialsMemoriesOrConversations() async throws {
        let harness = Harness()
        _ = try await harness.seedTask(
            title: "Collect prescription",
            due: now.addingTimeInterval(TimeSpan.hours(1)),
            importance: .high
        )
        try await harness.repositories.memories.store(
            MemoryItem(
                kind: .routine,
                content: "I need forty-five minutes to get ready",
                createdAt: now
            )
        )

        _ = await harness.service(at: now).refresh()

        let encoded = try [
            String(decoding: SystemSurfaceCoding.encode(harness.store.read(TodaySnapshot.self)), as: UTF8.self),
            String(decoding: SystemSurfaceCoding.encode(harness.store.read(TaskWidgetSnapshot.self)), as: UTF8.self),
            String(decoding: SystemSurfaceCoding.encode(harness.store.read(ReminderWidgetSnapshot.self)), as: UTF8.self),
        ].joined(separator: "\n")

        // Section 67: the memory informed the plan; it must not travel with it.
        XCTAssertFalse(encoded.contains("forty-five minutes"))
        for forbidden in ["apiKey", "api_key", "authorization", "bearer", "credential", "endpoint", "conversation", "transcript"] {
            XCTAssertFalse(
                encoded.lowercased().contains(forbidden.lowercased()),
                "a snapshot leaked '\(forbidden)'"
            )
        }
    }

    /// Section 36 and 76. A pass that changed nothing spends no refresh budget.
    func testAnUnchangedStoreReloadsNothing() async throws {
        let harness = Harness()
        _ = try await harness.seedTask(
            title: "Pay the electricity bill",
            due: now.addingTimeInterval(TimeSpan.hours(2)),
            importance: .high
        )

        let service = harness.service(at: now)
        let first = await service.refresh()
        let second = await service.refresh()

        XCTAssertFalse(first.reloadedKinds.isEmpty)
        XCTAssertTrue(
            second.reloadedKinds.isEmpty,
            "an unchanged day should not spend a WidgetKit refresh"
        )
        XCTAssertEqual(harness.reloader.reloads.count, first.reloadedKinds.count)
    }

    /// Section 85. A widget that cannot be written is a widget showing
    /// something slightly old — never an error that reaches anything else.
    func testAnUnavailableContainerIsReportedAndSurvived() async throws {
        let harness = Harness(storeAvailable: false)
        _ = try await harness.seedTask(
            title: "Pay the electricity bill",
            due: now.addingTimeInterval(TimeSpan.hours(1)),
            importance: .high
        )

        let report = await harness.service(at: now).refresh()
        XCTAssertTrue(report.sharedStorageUnavailable)
        XCTAssertTrue(report.reloadedKinds.isEmpty)
    }

    // MARK: Widget actions

    /// Section 99 and acceptance criterion 22. The widget's Done is the app's
    /// Done: `TaskStatusMachine`, pending support cancelled, repository written.
    func testWidgetDoneRoutesThroughTheStatusMachineAndCancelsSupport() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seedTaskWithReminder()

        // A reminder really is waiting with the OS before we start.
        let before = try await harness.platformRequestCount()
        XCTAssertEqual(before, 1)

        let outcome = try await harness.commands(at: now).complete(taskID: task.id)

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertTrue(outcome.didChange)

        let stored = try await harness.repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.status, .completed)
        XCTAssertNotNil(stored?.completedAt)

        let storedPlan = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertTrue(storedPlan?.pendingStages.isEmpty ?? false)
        let after = try await harness.platformRequestCount()
        XCTAssertEqual(after, 0, "finishing a task must withdraw its waiting reminders")

        // And the projection catches up.
        let report = await harness.service(at: now).refresh()
        XCTAssertTrue(report.reloadedKinds.contains(.today) || report.reloadedKinds.contains(.nextTask))
    }

    /// Section 100, and the rule the product is built on.
    func testWidgetSnoozeIsNotCompletion() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seedTaskWithReminder()
        let before = try await harness.repositories.reminderPlans
            .plan(id: plan.id)?.pendingStages.count ?? 0

        let outcome = try await harness.commands(at: now).snooze(taskID: task.id)

        XCTAssertNotEqual(outcome.status, .completed)
        let stored = try await harness.repositories.tasks.task(id: task.id)
        XCTAssertNotEqual(stored?.status, .completed)
        XCTAssertNil(stored?.completedAt)
        XCTAssertEqual(stored?.snoozeCount, 1)

        // Exactly one new stage, not none and not several. The original
        // reminder is untouched on purpose: the widget's "Later" is a statement
        // about the task, not an answer to a specific reminder, so a stage that
        // has not fired yet still will.
        let after = try await harness.repositories.reminderPlans
            .plan(id: plan.id)?.pendingStages.count ?? 0
        XCTAssertEqual(after, before + 1)
    }

    /// Section 101 and 41.
    func testWidgetImDoingItMarksInProgressRatherThanComplete() async throws {
        let harness = Harness()
        let (task, _) = try await harness.seedTaskWithReminder()

        let outcome = try await harness.commands(at: now).startWorking(taskID: task.id)

        XCTAssertEqual(outcome.status, .inProgress)
        XCTAssertNotEqual(outcome.status, .completed)
        let stored = try await harness.repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.status, .inProgress)
        XCTAssertNil(stored?.completedAt)
    }

    /// Pressing a widget button twice is one action. Widgets redraw, buttons
    /// get double-tapped, and the intent may run again.
    func testRepeatingAWidgetActionChangesNothingFurther() async throws {
        let harness = Harness()
        let (task, _) = try await harness.seedTaskWithReminder()
        let commands = harness.commands(at: now)

        let first = try await commands.complete(taskID: task.id)
        let second = try await commands.complete(taskID: task.id)

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(second.status, .completed)
    }

    // MARK: Provider independence

    /// Section 102 and 68. Widget content is deterministic prepared state, so
    /// which model the user selected cannot change it — and no provider is
    /// invoked to produce it.
    ///
    /// The structural half of the claim is stronger than the test:
    /// `SystemSurfaceService` and `SystemSurfaceCommandService` take
    /// repositories, platform services and pure policies. Neither has an
    /// `AIProviderRegistry` in scope to call.
    func testWidgetContentIsIdenticalUnderEveryProviderAndCallsNone() async throws {
        func build(with provider: StubAIProvider) async throws -> String {
            let harness = Harness()
            _ = try await harness.seedTask(
                title: "Collect prescription",
                due: now.addingTimeInterval(TimeSpan.hours(1)),
                importance: .high
            )
            // A full engine exists over the same store, exactly as it does in
            // the app. The surfaces still do not reach it.
            _ = AssistantEngine(
                providers: AIProviderRegistry(providers: [provider]),
                repositories: harness.repositories,
                services: harness.services,
                dateProvider: FixedDateProvider(now: now)
            )

            _ = await harness.service(at: now).refresh()
            let snapshot = try harness.store.read(TodaySnapshot.self)
            XCTAssertTrue(
                provider.receivedRequests.isEmpty,
                "building a widget snapshot called a provider"
            )
            return snapshot.items.map { "\($0.title)|\($0.kind.rawValue)|\($0.emphasis.rawValue)" }
                .joined(separator: ",")
        }

        let viaRemote = try await build(with: StubAIProvider(id: "remote.stub"))
        let viaApple = try await build(with: StubAIProvider(id: "apple.stub"))
        let viaLocal = try await build(with: StubAIProvider(id: "local.stub"))

        XCTAssertEqual(viaRemote, viaApple)
        XCTAssertEqual(viaApple, viaLocal)
        XCTAssertFalse(viaRemote.isEmpty)
    }

    // MARK: Live activities

    /// Section 107. Domain state maps to content state without requesting an
    /// actual system activity — which needs a device and a person looking at it.
    func testActiveSupportMapsToActivityContent() async throws {
        let harness = Harness()
        var task = try await harness.seedTask(
            title: "Dentist",
            due: now.addingTimeInterval(TimeSpan.minutes(50)),
            importance: .high
        )
        task.travelDuration = TimeSpan.minutes(15)
        task.preparationSteps = [
            PreparationStep(title: "Pack documents", estimatedDuration: TimeSpan.minutes(10), sequence: 0),
        ]
        try await harness.repositories.tasks.save(task)

        let timeline = PreparationPlanner().timeline(for: task, now: now)
        let candidate = try XCTUnwrap(
            LiveActivityPresentationPolicy.default.candidate(
                for: task,
                timeline: timeline,
                now: max(timeline?.startAt ?? now, now)
            )
        )
        let content = SystemSurfaceSnapshotBuilder().activityContent(for: candidate, task: task)

        XCTAssertEqual(content.title, "Dentist")
        XCTAssertTrue(content.phase == .preparing || content.phase == .leaving)
        XCTAssertEqual(content.nextStep, "Pack documents")
        XCTAssertEqual(content.totalSteps, 1)
        // Section 50: compact. No plan, no history, no memory.
        let json = try String(decoding: JSONEncoder().encode(content), as: UTF8.self)
        XCTAssertLessThan(json.count, 512)
    }

    /// Section 108's positive case, end to end through the service.
    func testAnActivityIsStartedForActivePreparationAndOnlyOnce() async throws {
        let harness = Harness()
        var task = try await harness.seedTask(
            title: "Dentist",
            due: now.addingTimeInterval(TimeSpan.minutes(40)),
            importance: .high
        )
        task.travelDuration = TimeSpan.minutes(10)
        try await harness.repositories.tasks.save(task)

        let service = harness.service(at: now)
        let first = await service.refresh()
        XCTAssertEqual(first.activitiesStarted, 1)

        // Section 111: running again must not start a second one for the same
        // task, which is the duplicate a relaunch would otherwise produce.
        let second = await service.refresh()
        XCTAssertEqual(second.activitiesStarted, 0)

        let starts = await harness.activities.starts(for: task.id.rawValue)
        XCTAssertEqual(starts, 1)
    }

    /// Section 47. The common case produces nothing at all.
    func testNoActivityIsStartedForAnOrdinaryTask() async throws {
        let harness = Harness()
        _ = try await harness.seedTask(
            title: "Return the library book",
            due: now.addingTimeInterval(TimeSpan.days(6)),
            importance: .normal
        )

        let report = await harness.service(at: now).refresh()
        XCTAssertEqual(report.activitiesStarted, 0)
    }

    /// Section 109. The phase follows the domain, not a timer.
    func testTheActivityUpdatesAsThePhaseChanges() async throws {
        let harness = Harness()
        var task = try await harness.seedTask(
            title: "Dentist",
            due: now.addingTimeInterval(TimeSpan.minutes(60)),
            importance: .high
        )
        task.travelDuration = TimeSpan.minutes(15)
        try await harness.repositories.tasks.save(task)

        _ = await harness.service(at: now).refresh()
        let preparing = await harness.activities.content[task.id.rawValue]

        // Twenty minutes later the leave time is close.
        let later = now.addingTimeInterval(TimeSpan.minutes(35))
        let report = await harness.service(at: later).refresh()
        let leaving = await harness.activities.content[task.id.rawValue]

        XCTAssertNotNil(preparing)
        XCTAssertNotNil(leaving)
        XCTAssertGreaterThanOrEqual(report.activitiesUpdated, 0)
        XCTAssertEqual(leaving?.phase, .leaving)
    }

    /// Section 110 and 62. Completing the task ends the activity — the
    /// coordinator is told, and nothing is left presenting.
    func testCompletingTheTaskEndsItsActivity() async throws {
        let harness = Harness()
        var task = try await harness.seedTask(
            title: "Dentist",
            due: now.addingTimeInterval(TimeSpan.minutes(40)),
            importance: .high
        )
        task.travelDuration = TimeSpan.minutes(10)
        try await harness.repositories.tasks.save(task)

        let service = harness.service(at: now)
        _ = await service.refresh()

        _ = try await harness.commands(at: now).complete(taskID: task.id)
        let report = await service.refresh()

        XCTAssertEqual(report.activitiesEnded, 1)
        let registry = try harness.store.read(LiveActivityRegistry.self)
        XCTAssertTrue(registry.activities.isEmpty)
    }

    /// Section 111. A fresh service over the same shared state — the app was
    /// relaunched — finds the activity already registered and does not start a
    /// second one.
    func testARelaunchReconcilesRatherThanDuplicating() async throws {
        let harness = Harness()
        var task = try await harness.seedTask(
            title: "Dentist",
            due: now.addingTimeInterval(TimeSpan.minutes(45)),
            importance: .high
        )
        task.travelDuration = TimeSpan.minutes(10)
        try await harness.repositories.tasks.save(task)

        _ = await harness.service(at: now).refresh()
        // A different `SystemSurfaceService` instance over the same store and
        // the same repositories.
        let afterRelaunch = await harness.service(at: now.addingTimeInterval(60)).refresh()

        XCTAssertEqual(afterRelaunch.activitiesStarted, 0)
        let starts = await harness.activities.starts(for: task.id.rawValue)
        XCTAssertEqual(starts, 1)
    }

    /// Section 84. Live Activities switched off is not a failure of anything
    /// else — the task, its reminders and the widgets all carry on.
    func testActivitiesBeingUnavailableChangesNothingElse() async throws {
        let harness = Harness(activitiesAvailable: false)
        var task = try await harness.seedTask(
            title: "Dentist",
            due: now.addingTimeInterval(TimeSpan.minutes(40)),
            importance: .high
        )
        task.travelDuration = TimeSpan.minutes(10)
        try await harness.repositories.tasks.save(task)

        let report = await harness.service(at: now).refresh()

        XCTAssertEqual(report.activitiesStarted, 0)
        XCTAssertFalse(report.reloadedKinds.isEmpty, "widgets still update")
        XCTAssertGreaterThan(report.todayItems, 0)
    }

    /// Section 89. The user's own switch, honoured independently of the
    /// system's — and turning it off ends what is already running.
    func testTurningLiveActivitiesOffEndsTheRunningOnes() async throws {
        let harness = Harness()
        var task = try await harness.seedTask(
            title: "Dentist",
            due: now.addingTimeInterval(TimeSpan.minutes(40)),
            importance: .high
        )
        task.travelDuration = TimeSpan.minutes(10)
        try await harness.repositories.tasks.save(task)

        let service = harness.service(at: now)
        _ = await service.refresh()

        await service.setLiveActivitiesEnabled(false)
        let report = await service.refresh()

        XCTAssertEqual(report.activitiesEnded, 1)
        XCTAssertEqual(report.activitiesStarted, 0)
    }

    // MARK: Part 11

    /// Section 112 and 140. The app was away through a preparation transition.
    /// Reconciliation recalculates the domain; the projections and the activity
    /// follow it. There is no second recovery path.
    func testPartElevenReconciliationDrivesTheSurfaces() async throws {
        let harness = Harness()
        let (task, _) = try await harness.seedTaskWithReminder(
            due: now, importance: .high
        )

        // Three hours later: the reminder came due while the app was gone.
        let later = now.addingTimeInterval(TimeSpan.hours(3))
        let reconciliation = SupportReconciliationService(
            repositories: harness.repositories,
            services: harness.services,
            routines: RoutineService(
                repositories: harness.repositories,
                services: harness.services,
                dateProvider: FixedDateProvider(now: later)
            ),
            dateProvider: FixedDateProvider(now: later)
        )

        let pass = try await reconciliation.reconcile(trigger: .launch)
        XCTAssertEqual(pass.missedStages, 1)

        // The surfaces are refreshed from whatever reconciliation concluded.
        let report = await harness.service(at: later).refresh(reason: .reconciliation)
        XCTAssertFalse(report.reloadedKinds.isEmpty)

        let stored = try await harness.repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.status, .needsFollowUp)

        let support = try harness.store.read(ReminderWidgetSnapshot.self)
        XCTAssertEqual(support.taskID, task.id.rawValue, "the widget shows the recovered support")
    }

    // MARK: Harness

    private final class Harness {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let store: InMemorySystemSurfaceStore
        let reloader = RecordingReloader()
        let activities: RecordingLiveActivityCoordinator

        init(storeAvailable: Bool = true, activitiesAvailable: Bool = true) {
            self.store = InMemorySystemSurfaceStore(isAvailable: storeAvailable)
            self.activities = RecordingLiveActivityCoordinator(isAvailable: activitiesAvailable)
        }

        func service(at date: Date) -> SystemSurfaceService {
            SystemSurfaceService(
                repositories: repositories,
                store: store,
                reloader: reloader,
                activities: activities,
                dateProvider: FixedDateProvider(now: date)
            )
        }

        func commands(at date: Date) -> SystemSurfaceCommandService {
            SystemSurfaceCommandService(
                repositories: repositories,
                services: services,
                dateProvider: FixedDateProvider(now: date)
            )
        }

        func platformRequestCount() async throws -> Int {
            let pending = try await services.notifications.pendingNotifications()
            let alarms = try await services.alarms.scheduledAlarms()
            return pending.count + alarms.count
        }

        @discardableResult
        func seedTask(
            title: String,
            due: Date?,
            importance: Importance
        ) async throws -> TaskItem {
            let task = TaskItem(
                title: title,
                status: .notStarted,
                importance: importance,
                timing: due.map { .dueBy($0) } ?? .unscheduled,
                deadline: due,
                createdAt: Date(timeIntervalSince1970: 1_759_000_000)
            )
            try await repositories.tasks.save(task)
            return task
        }

        /// A task with a reminder plan whose stage has been handed to the mock
        /// platform, so "completion withdraws it" is a real assertion.
        func seedTaskWithReminder(
            due: Date? = nil,
            importance: Importance = .normal
        ) async throws -> (TaskItem, ReminderPlan) {
            let fireDate = due ?? Date(timeIntervalSince1970: 1_760_000_000)
            var task = TaskItem(
                title: "Pay the electricity bill",
                status: .reminded,
                importance: importance,
                timing: .dueBy(fireDate),
                deadline: fireDate,
                createdAt: Date(timeIntervalSince1970: 1_759_000_000)
            )
            let stage = ReminderStage(
                kind: .finalCall,
                offset: .absolute(fireDate),
                escalation: .standard,
                message: "Pay the electricity bill",
                requiresConfirmation: true,
                scheduledFor: fireDate
            )
            let plan = ReminderPlan(
                subject: ReminderSubject(
                    reference: .task(task.id),
                    title: task.title,
                    anchor: .deadline(fireDate),
                    importance: importance
                ),
                stages: [stage],
                createdAt: Date(timeIntervalSince1970: 1_759_000_000),
                generatedBy: "test"
            )
            task.reminderPlanID = plan.id
            try await repositories.reminderPlans.save(plan)
            try await repositories.tasks.save(task)

            _ = try await services.notifications.schedule(
                NotificationRequest(
                    id: NotificationRequest.ID(stage.id.rawValue),
                    title: task.title,
                    body: stage.message,
                    fireDate: fireDate,
                    relatedTaskID: task.id,
                    stageID: stage.id,
                    planRevision: plan.revision
                )
            )
            return (task, plan)
        }
    }

    /// Counts reload requests, so section 36's restraint is assertable.
    /// A lock rather than an actor, deliberately.
    ///
    /// `SystemSurfaceReloader.reload` is synchronous — it has to be, because
    /// WidgetKit's own reload is — so an actor-backed double can only record by
    /// spawning `Task { await record(kind) }`. That leaves three unawaited
    /// tasks in flight, and a test that then hops to the actor to read the
    /// count has no ordering guarantee against them. It wins that race almost
    /// every time and loses it under load, which is the worst kind of test: one
    /// that fails on a busy machine and passes on the machine you debug it on.
    ///
    /// A lock makes the record land before `reload` returns, so there is no
    /// race left to lose.
    private final class RecordingReloader: SystemSurfaceReloader, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SystemSurfaceWidgetKind] = []

        var reloads: [SystemSurfaceWidgetKind] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func reload(_ kind: SystemSurfaceWidgetKind) {
            lock.lock()
            storage.append(kind)
            lock.unlock()
        }
    }
}
