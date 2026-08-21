import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import MockPlatform
import XCTest

/// Routines wired to real repositories and the mock platform layer.
///
/// `RoutineSchedulerTests` covers the policy. This covers what the policy is
/// plugged into: that occurrences are persisted once, that they get the same
/// reminder support any other fixed-time task gets, and that resolving one
/// actually withdraws the notifications iOS is still holding.
final class RoutineServiceTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }

    private func makeService(
        repositories: AssistantRepositories,
        services: PlatformServices,
        now: Date
    ) -> RoutineService {
        RoutineService(
            repositories: repositories,
            services: services,
            dateProvider: FixedDateProvider(
                now: now,
                timeZone: TimeZone(identifier: "Europe/London")!
            )
        )
    }

    private func routine(
        hour: Int = 9,
        recovery: RoutineRecoveryPolicy = RoutineRecoveryPolicy()
    ) -> Routine {
        Routine(
            title: "Take medication",
            recurrence: RecurrenceRule(
                frequency: .daily,
                timeOfDay: TimeOfDay(hour: hour),
                startDate: date(1)
            ),
            recovery: recovery,
            createdAt: date(1)
        )
    }

    // MARK: Creation

    func testCreatingARoutineMaterialisesWhatItAlreadyOwes() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        // Five minutes before the first dose: it has to work at nine, not at
        // the next reconciliation.
        let service = makeService(repositories: repositories, services: services, now: date(10, 8))

        let result = try await service.create(routine())

        XCTAssertFalse(result.created.isEmpty)
        let stored = try await repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(stored.count, result.created.count)
        XCTAssertTrue(stored.allSatisfy(\.isRoutineOccurrence))
    }

    func testAnImpossibleRuleIsRefusedBeforeAnythingIsSaved() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(
            repositories: repositories,
            services: .mock(),
            now: date(10, 8)
        )

        let broken = Routine(
            title: "Nonsense",
            recurrence: RecurrenceRule(
                frequency: .weekly,
                timeOfDay: TimeOfDay(hour: 9),
                startDate: date(1)
            ),
            createdAt: date(1)
        )

        do {
            _ = try await service.create(broken)
            XCTFail("a weekly rule with no weekdays should not be accepted")
        } catch {
            // Nothing written: validation happens before the save, so a refused
            // rule leaves no half-created routine behind.
        }

        let stored = try await repositories.routines.routines(activeOnly: false)
        XCTAssertTrue(stored.isEmpty)
    }

    func testEachOccurrenceGetsItsOwnReminderPlan() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(
            repositories: repositories,
            services: .mock(),
            now: date(10, 8)
        )

        let result = try await service.create(routine())
        let first = try XCTUnwrap(result.created.first)

        // Read back, because the plan link is written after the occurrence is
        // saved — returning an unlinked value would be the easy bug here.
        let loaded = try await repositories.tasks.task(id: first.id)
        let stored = try XCTUnwrap(loaded)
        let planID = try XCTUnwrap(stored.reminderPlanID)
        let plan = try await repositories.reminderPlans.plan(id: planID)
        XCTAssertEqual(plan?.subject.reference, .task(first.id))
    }

    // MARK: Reconciliation

    /// Relaunching does not multiply the mornings.
    func testReconcilingTwiceCreatesOneSetOfOccurrences() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(
            repositories: repositories,
            services: .mock(),
            now: date(10, 8)
        )

        _ = try await service.create(routine())
        let countAfterFirst = try await repositories.tasks.tasks(matching: TaskFilter()).count

        _ = try await service.reconcileAll()
        let countAfterSecond = try await repositories.tasks.tasks(matching: TaskFilter()).count

        XCTAssertEqual(countAfterFirst, countAfterSecond)
    }

    func testAPausedRoutineStopsProducingOccurrences() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(
            repositories: repositories,
            services: .mock(),
            now: date(10, 8)
        )

        let routine = routine()
        _ = try await service.create(routine)
        let before = try await repositories.tasks.tasks(matching: TaskFilter()).count

        _ = try await service.setActive(false, routineID: routine.id)
        _ = try await service.reconcileAll()

        // The existing occurrences keep their own lives; no new ones appear.
        let after = try await repositories.tasks.tasks(matching: TaskFilter()).count
        XCTAssertEqual(after, before)
    }

    // MARK: Expiry

    /// Section 10, and the reason this test bothers with the mock platform: an
    /// expired occurrence that still buzzes at nine o'clock is worse than one
    /// nobody cancelled, because now the app is visibly wrong.
    func testAnExpiredOccurrenceHasItsPendingNotificationsWithdrawn() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let routine = routine(recovery: RoutineRecoveryPolicy(window: TimeSpan.hours(2)))

        // Create the occurrences the morning of.
        let morning = makeService(repositories: repositories, services: services, now: date(10, 8))
        let created = try await morning.create(routine)
        let occurrence = try XCTUnwrap(created.created.first)

        // Schedule something against the plan's first stage, standing in for
        // what the app would have handed to iOS.
        let storedOccurrence = try await repositories.tasks.task(id: occurrence.id)
        let planID = try XCTUnwrap(storedOccurrence?.reminderPlanID)
        let loadedPlan = try await repositories.reminderPlans.plan(id: planID)
        let plan = try XCTUnwrap(loadedPlan)
        let stage = try XCTUnwrap(plan.stages.first)
        _ = try await services.notifications.schedule(
            NotificationRequest(
                id: NotificationRequest.ID(stage.id.rawValue),
                title: routine.title,
                body: "…",
                fireDate: date(10, 9),
                relatedTaskID: occurrence.id,
                stageID: stage.id
            )
        )
        let beforeExpiry = try await services.notifications.pendingNotifications()
        XCTAssertEqual(beforeExpiry.count, 1)

        // Long past the recovery window.
        let evening = makeService(repositories: repositories, services: services, now: date(10, 20))
        let result = try await evening.reconcileAll()

        XCTAssertTrue(result.expired.contains { $0.id == occurrence.id })
        let loaded = try await repositories.tasks.task(id: occurrence.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.status, .expired)
        XCTAssertNil(stored.completedAt)

        let afterExpiry = try await services.notifications.pendingNotifications()
        XCTAssertTrue(afterExpiry.isEmpty)
    }

    func testExpiringAnOccurrenceLeavesTheRoutineRunning() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let routine = routine(recovery: .none)

        let morning = makeService(repositories: repositories, services: .mock(), now: date(10, 8))
        _ = try await morning.create(routine)

        let evening = makeService(repositories: repositories, services: .mock(), now: date(10, 20))
        _ = try await evening.reconcileAll()

        let loaded = try await repositories.routines.routine(id: routine.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertTrue(stored.isActive)
        XCTAssertNotNil(stored.lastMissedAt)
    }

    // MARK: Skipping

    func testSkippingOneOccurrenceResolvesItAndLeavesTheRoutineAlone() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let service = makeService(
            repositories: repositories,
            services: .mock(),
            now: date(10, 8)
        )

        let routine = routine()
        let created = try await service.create(routine)
        let occurrence = try XCTUnwrap(created.created.first)

        let skipped = try await service.skipOccurrence(occurrence.id)

        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertFalse(skipped.status.isSuccess)

        let loaded = try await repositories.routines.routine(id: routine.id)
        XCTAssertTrue(try XCTUnwrap(loaded).isActive)
    }
}
