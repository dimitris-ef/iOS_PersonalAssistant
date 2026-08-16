#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import ExecutiveSupport
import XCTest

/// Follow-up state has to survive the app closing.
///
/// A support system that forgets it was chasing something the moment the
/// process ends is not a support system. These go through the real SwiftData
/// repositories and reopen the store between writing and reading.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class FollowUpPersistenceTests: PersistenceTestCase {

    func testStageStateSurvivesARelaunch() async throws {
        let (task, plan) = try await seed()

        var updated = plan
        updated.recordOutcome(.dismissed, forStage: plan.stages[0].id, at: Self.referenceDate)
        updated.stages.append(followUpStage(at: Self.referenceDate.addingTimeInterval(1_800)))
        try await repositories.reminderPlans.save(updated)

        try relaunch()

        let reloaded = try await repositories.reminderPlans.plan(id: plan.id)
        let loaded = try XCTUnwrap(reloaded)

        XCTAssertEqual(loaded.stages.count, 2)
        XCTAssertEqual(loaded.stage(id: plan.stages[0].id)?.state, .dismissed)
        XCTAssertEqual(loaded.stage(id: plan.stages[0].id)?.stateChangedAt, Self.referenceDate)
        XCTAssertEqual(loaded.pendingStages.count, 1)
        XCTAssertEqual(loaded.pendingStages.first?.kind, .followUp)
        XCTAssertEqual(
            loaded.nextPendingStage?.scheduledFor,
            Self.referenceDate.addingTimeInterval(1_800)
        )
        XCTAssertNotNil(task.id)
    }

    func testEveryStageStateRoundTrips() async throws {
        let (_, plan) = try await seed()

        for state in ReminderStageState.allCases {
            var updated = plan
            updated.stages[0].transition(to: state, at: Self.referenceDate)
            try await repositories.reminderPlans.save(updated)

            let reloaded = try await repositories.reminderPlans.plan(id: plan.id)
            XCTAssertEqual(reloaded?.stages.first?.state, state)
        }
    }

    /// The whole point, end to end: dismissal, relaunch, still being chased.
    func testAFollowUpCreatedByDismissalIsStillThereAfterARelaunch() async throws {
        let (task, plan) = try await seed()

        let decision = FollowUpCoordinator().apply(
            outcome: .dismissed,
            toStage: plan.stages[0].id,
            task: task,
            plan: plan,
            context: planningContext()
        )
        try await repositories.reminderPlans.save(decision.plan)
        try await repositories.tasks.save(decision.task)

        try relaunch()

        let reloadedTask = try await repositories.tasks.task(id: task.id)
        let reloadedPlan = try await repositories.reminderPlans.plan(id: plan.id)

        XCTAssertEqual(reloadedTask?.status, .needsFollowUp)
        XCTAssertNotEqual(reloadedTask?.status, .completed)
        XCTAssertEqual(reloadedTask?.followUpCount, 1)
        XCTAssertEqual(reloadedPlan?.pendingStages.count, 1)
        XCTAssertGreaterThan(
            reloadedPlan?.nextPendingStage?.scheduledFor ?? .distantPast,
            Self.referenceDate
        )
    }

    /// Attempt counts are what make escalation work across launches. If they
    /// reset, the third missed reminder is treated like the first forever.
    func testEscalationStateSurvivesARelaunch() async throws {
        var (task, plan) = try await seed()

        task.followUpCount = 3
        task.snoozeCount = 2
        task.status = .needsFollowUp
        try await repositories.tasks.save(task)

        plan.stages[0].escalation = .insistent
        plan.stages[0].transition(to: .missed, at: Self.referenceDate)
        try await repositories.reminderPlans.save(plan)

        try relaunch()

        let reloadedTask = try await repositories.tasks.task(id: task.id)
        let reloadedPlan = try await repositories.reminderPlans.plan(id: plan.id)

        XCTAssertEqual(reloadedTask?.followUpCount, 3)
        XCTAssertEqual(reloadedTask?.snoozeCount, 2)
        XCTAssertEqual(reloadedPlan?.stages.first?.escalation, .insistent)
        XCTAssertEqual(reloadedPlan?.stages.first?.state, .missed)
    }

    func testCompletionCancelsPendingRemindersDurably() async throws {
        let (task, plan) = try await seed()

        let decision = FollowUpCoordinator().apply(
            outcome: .completed,
            toStage: plan.stages[0].id,
            task: task,
            plan: plan,
            context: planningContext()
        )
        try await repositories.reminderPlans.save(decision.plan)
        try await repositories.tasks.save(decision.task)

        try relaunch()

        let reloadedTask = try await repositories.tasks.task(id: task.id)
        let reloadedPlan = try await repositories.reminderPlans.plan(id: plan.id)

        XCTAssertEqual(reloadedTask?.status, .completed)
        XCTAssertTrue(reloadedPlan?.pendingStages.isEmpty ?? false)

        // And a stale callback arriving after the relaunch changes nothing.
        let stale = FollowUpCoordinator().apply(
            outcome: .missed,
            toStage: plan.stages[0].id,
            task: try XCTUnwrap(reloadedTask),
            plan: try XCTUnwrap(reloadedPlan),
            context: planningContext(at: Self.referenceDate.addingTimeInterval(3_600))
        )
        XCTAssertEqual(stale.task.status, .completed)
        XCTAssertTrue(stale.schedule.isEmpty)
    }

    /// Providers are interchangeable reasoning engines. Support belongs to the
    /// application, so switching model must not disturb any of it.
    func testSwitchingProviderLeavesFollowUpStateAlone() async throws {
        let (task, plan) = try await seed()

        let decision = FollowUpCoordinator().apply(
            outcome: .dismissed,
            toStage: plan.stages[0].id,
            task: task,
            plan: plan,
            context: planningContext()
        )
        try await repositories.reminderPlans.save(decision.plan)
        try await repositories.tasks.save(decision.task)

        let expectedPending = decision.plan.pendingStages.count
        let expectedNext = decision.plan.nextPendingStage?.scheduledFor

        for provider: AIProviderIdentifier in ["remote.openai-compatible", "dev.scripted"] {
            var settings = try await repositories.settings.settings()
            settings.preferredProviderID = provider
            try await repositories.settings.update(settings)

            try relaunch()

            let reloadedTask = try await repositories.tasks.task(id: task.id)
            let reloadedPlan = try await repositories.reminderPlans.plan(id: plan.id)

            XCTAssertEqual(reloadedTask?.status, .needsFollowUp)
            XCTAssertEqual(reloadedTask?.followUpCount, 1)
            XCTAssertEqual(reloadedPlan?.pendingStages.count, expectedPending)
            XCTAssertEqual(reloadedPlan?.nextPendingStage?.scheduledFor, expectedNext)
        }
    }

    /// Saving a plan repeatedly must not accumulate follow-ups — the app reloads
    /// and re-saves plans routinely.
    func testResavingAPlanDoesNotMultiplyItsStages() async throws {
        let (_, plan) = try await seed()

        var updated = plan
        updated.stages.append(followUpStage(at: Self.referenceDate.addingTimeInterval(600)))

        for _ in 0..<3 {
            try await repositories.reminderPlans.save(updated)
        }

        try relaunch()

        let reloaded = try await repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(reloaded?.stages.count, 2)
        XCTAssertEqual(reloaded?.pendingStages.count, 1)
    }

    // MARK: Fixtures

    private func planningContext(at date: Date? = nil) -> SupportPlanningContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return SupportPlanningContext(
            profile: UserProfile(),
            preferences: SupportPreferences(),
            now: date ?? Self.referenceDate,
            calendar: calendar
        )
    }

    private func followUpStage(at date: Date) -> ReminderStage {
        ReminderStage(
            kind: .followUp,
            offset: .absolute(date),
            message: "Still open",
            state: .pending,
            stateChangedAt: Self.referenceDate,
            scheduledFor: date
        )
    }

    private func seed() async throws -> (TaskItem, ReminderPlan) {
        var task = TaskItem(
            title: "Pay the electricity bill",
            status: .reminded,
            importance: .high,
            deadline: Self.referenceDate.addingTimeInterval(TimeSpan.hours(2)),
            createdAt: Self.referenceDate.addingTimeInterval(-TimeSpan.hours(6))
        )

        let stage = ReminderStage(
            kind: .finalCall,
            offset: .absolute(Self.referenceDate),
            message: "Pay the electricity bill",
            requiresConfirmation: true,
            state: .delivered,
            stateChangedAt: Self.referenceDate,
            scheduledFor: Self.referenceDate
        )

        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(task.id),
                title: task.title,
                anchor: .deadline(Self.referenceDate.addingTimeInterval(TimeSpan.hours(2))),
                importance: .high
            ),
            stages: [stage],
            createdAt: Self.referenceDate.addingTimeInterval(-TimeSpan.hours(6)),
            generatedBy: "test"
        )

        task.reminderPlanID = plan.id
        try await repositories.reminderPlans.save(plan)
        try await repositories.tasks.save(task)
        return (task, plan)
    }
}

#endif
