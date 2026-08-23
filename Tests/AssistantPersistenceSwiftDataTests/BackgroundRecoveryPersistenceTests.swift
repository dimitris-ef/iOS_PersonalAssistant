#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import ExecutiveSupport
import Foundation
import XCTest

/// Schema V9: what the app has to remember in order to recover.
///
/// Section 2. Persisted domain state is the source of truth, and everything the
/// milestone adds is in service of one question the app must be able to answer
/// on a cold launch with no network and no memory of the last run: *what was I
/// supposed to be doing, and has it already been dealt with?*
///
/// Section 114 asks that the reconciliation path and the app share one store.
/// These tests go through the real SwiftData repositories and reopen the
/// container between writing and reading — the closest a test can get to
/// quitting and reopening the app.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class BackgroundRecoveryPersistenceTests: PersistenceTestCase {

    /// Section 55: a small mapping, not a serialized `UNNotificationRequest`.
    /// The request is rebuilt from domain data every time, so storing one would
    /// be storing a stale copy of something derivable.
    func testStageDeliveryStateSurvivesARelaunch() async throws {
        let (_, plan) = try await seed()

        var updated = plan
        updated.stages[0].delivery.succeeded(at: Self.referenceDate, revision: 3)
        try await repositories.reminderPlans.save(updated)

        try relaunch()

        let reloaded = try await repositories.reminderPlans.plan(id: plan.id)
        let delivery = try XCTUnwrap(reloaded?.stages.first?.delivery)

        XCTAssertEqual(delivery.state, .scheduled)
        XCTAssertEqual(delivery.attempts, 1)
        XCTAssertEqual(delivery.scheduledRevision, 3)
        XCTAssertEqual(delivery.lastAttemptAt, Self.referenceDate)
        XCTAssertNil(delivery.failureReason)
    }

    func testEveryDeliveryStateRoundTrips() async throws {
        let (_, plan) = try await seed()

        for state in StageDeliveryState.allCases {
            var updated = plan
            updated.stages[0].delivery = StageDelivery(
                state: state,
                lastAttemptAt: Self.referenceDate,
                attempts: 2,
                failureReason: state.isRetryable ? nil : "notifications permission denied",
                scheduledRevision: state.isLive ? 1 : nil
            )
            try await repositories.reminderPlans.save(updated)

            let reloaded = try await repositories.reminderPlans.plan(id: plan.id)
            XCTAssertEqual(reloaded?.stages.first?.delivery.state, state)
            XCTAssertEqual(reloaded?.stages.first?.delivery.attempts, 2)
        }
    }

    /// Section 61 and 102. Notifications are off; the reminder still exists. A
    /// relaunch must not turn "we could not deliver this" into "there was
    /// nothing to deliver".
    func testAnUndeliverableReminderIsStillAReminderAfterARelaunch() async throws {
        let (_, plan) = try await seed()

        var updated = plan
        updated.stages[0].delivery.failed(
            at: Self.referenceDate,
            reason: "notifications permission denied",
            isPermanent: true
        )
        try await repositories.reminderPlans.save(updated)

        try relaunch()

        let reloaded = try await repositories.reminderPlans.plan(id: plan.id)
        let stage = try XCTUnwrap(reloaded?.stages.first)

        XCTAssertTrue(stage.state.isPending, "the domain reminder survives a delivery failure")
        XCTAssertEqual(stage.delivery.state, .unavailable)
        XCTAssertFalse(stage.wantsDelivery)
        XCTAssertEqual(stage.delivery.failureReason, "notifications permission denied")
    }

    /// Section 17. The revision is what a notification callback is checked
    /// against, so losing it across a relaunch would make every reminder in
    /// flight either uncheckable or wrongly stale.
    func testThePlanRevisionSurvivesARelaunch() async throws {
        let (_, plan) = try await seed()

        var updated = plan
        updated.touch()
        updated.touch()
        try await repositories.reminderPlans.save(updated)

        try relaunch()

        let reloaded = try await repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(reloaded?.revision, plan.revision + 2)
    }

    /// Sections 49 to 52, and the reason this is a table rather than something
    /// held in memory: the duplicate a notification callback has to defend
    /// against may arrive in a process that did not exist when the first one
    /// was answered.
    func testAHandledActionClaimSurvivesARelaunch() async throws {
        let action = HandledSupportAction(
            stageID: ReminderStage.ID(),
            taskID: TaskItem.ID(),
            action: "dismissed",
            revision: 2,
            handledAt: Self.referenceDate
        )

        let first = try await repositories.supportActions.claim(action)
        XCTAssertTrue(first)

        try relaunch()

        let second = try await repositories.supportActions.claim(action)
        XCTAssertFalse(second, "the same answer, redelivered after a relaunch, is not a new answer")
        let handled = try await repositories.supportActions.wasHandled(action.id)
        XCTAssertTrue(handled)
    }

    /// Different actions on one stage are different claims. Dismissing and then
    /// finishing on the same notification sheet must both land.
    func testClaimsAreScopedToTheActionAndRevision() async throws {
        let stage = ReminderStage.ID()
        let task = TaskItem.ID()

        let dismissed = HandledSupportAction(
            stageID: stage, taskID: task, action: "dismissed", revision: 1,
            handledAt: Self.referenceDate
        )
        let completed = HandledSupportAction(
            stageID: stage, taskID: task, action: "completed", revision: 1,
            handledAt: Self.referenceDate
        )
        let nextRevision = HandledSupportAction(
            stageID: stage, taskID: task, action: "dismissed", revision: 2,
            handledAt: Self.referenceDate
        )

        let a = try await repositories.supportActions.claim(dismissed)
        let b = try await repositories.supportActions.claim(completed)
        let c = try await repositories.supportActions.claim(nextRevision)

        XCTAssertTrue(a)
        XCTAssertTrue(b)
        XCTAssertTrue(c)
    }

    func testPruningDropsOnlyTheOldClaims() async throws {
        let old = HandledSupportAction(
            stageID: ReminderStage.ID(),
            taskID: TaskItem.ID(),
            action: "snoozed",
            revision: 1,
            handledAt: Self.referenceDate.addingTimeInterval(-TimeSpan.days(90))
        )
        let recent = HandledSupportAction(
            stageID: ReminderStage.ID(),
            taskID: TaskItem.ID(),
            action: "snoozed",
            revision: 1,
            handledAt: Self.referenceDate
        )
        _ = try await repositories.supportActions.claim(old)
        _ = try await repositories.supportActions.claim(recent)

        try await repositories.supportActions.prune(
            before: Self.referenceDate.addingTimeInterval(-TimeSpan.days(30))
        )
        try relaunch()

        let oldSurvives = try await repositories.supportActions.wasHandled(old.id)
        let recentSurvives = try await repositories.supportActions.wasHandled(recent.id)
        XCTAssertFalse(oldSurvives)
        XCTAssertTrue(recentSurvives)
    }

    // MARK: Fixtures

    private func seed() async throws -> (TaskItem, ReminderPlan) {
        var task = TaskItem(
            title: "Pay the electricity bill",
            status: .reminded,
            importance: .normal,
            createdAt: Self.referenceDate.addingTimeInterval(-TimeSpan.hours(6))
        )
        let stage = ReminderStage(
            kind: .finalCall,
            offset: .absolute(Self.referenceDate),
            message: "Pay the electricity bill",
            requiresConfirmation: true,
            scheduledFor: Self.referenceDate
        )
        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(task.id),
                title: task.title,
                anchor: .unscheduled,
                importance: .normal
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
