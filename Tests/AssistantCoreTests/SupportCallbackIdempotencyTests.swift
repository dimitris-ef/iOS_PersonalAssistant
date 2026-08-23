import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import Foundation
import MockPlatform
import XCTest

@testable import AssistantCore

/// What comes back from the lock screen, and how often.
///
/// ## Why any of this is needed
///
/// A notification callback is not a function call. iOS can deliver the same
/// response twice after a crash; a cold launch triggered by a lock-screen action
/// can race a foreground reconciliation doing the same work; the user can tap a
/// button twice because the first tap did not appear to do anything. The
/// defence has to survive a process boundary, which is why it is a persisted
/// claim (sections 49 to 52) rather than anything held in memory.
///
/// ## And the rule underneath all of it
///
/// Sections 21 to 25. Dismissal is not completion. Acknowledgement is not
/// completion. Snooze is not completion. Only an explicit Done completes a task,
/// and no amount of repetition turns one of the others into it.
final class SupportCallbackIdempotencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: Duplicates

    /// Section 98. The same Done, delivered twice.
    func testDuplicateCompletionCallbacksCompleteTheTaskOnce() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()
        let service = harness.followUp(at: now)

        let first = try await service.handle(
            outcome: .completed,
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: plan.revision
        )
        let second = try await service.handle(
            outcome: .completed,
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: plan.revision
        )

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(first.task.status, .completed)
        XCTAssertEqual(second.task.status, .completed)
        XCTAssertEqual(first.task.completedAt, second.task.completedAt)

        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 0)
    }

    /// Section 99. Two Snoozes must move the reminder once, not twice — and must
    /// not count as two snoozes, which would escalate for no reason.
    func testDuplicateSnoozeCallbacksSnoozeOnce() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()
        let service = harness.followUp(at: now)
        let until = now.addingTimeInterval(TimeSpan.minutes(30))

        let first = try await service.handle(
            outcome: .snoozed(until: until),
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: plan.revision
        )
        let second = try await service.handle(
            outcome: .snoozed(until: until),
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: plan.revision
        )

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertNil(second.nextReminder)

        let stored = try await harness.repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.snoozeCount, 1)
        XCTAssertNotEqual(stored?.status, .completed)

        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 1)
    }

    /// Section 108, and the product's founding rule. Dismissing twice is still
    /// not finishing.
    func testDuplicateDismissalsNeverCompleteTheTask() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()
        let service = harness.followUp(at: now)

        for _ in 0..<3 {
            _ = try await service.handle(
                outcome: .dismissed,
                forTask: task.id,
                stageID: plan.stages[0].id,
                revision: plan.revision
            )
        }

        let stored = try await harness.repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.status, .needsFollowUp)
        XCTAssertNotEqual(stored?.status, .completed)
        XCTAssertNil(stored?.completedAt)

        // One follow-up, not three.
        let storedPlan = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(storedPlan?.pendingStages.count, 1)
        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 1)
    }

    /// Section 24. "I'm doing it" is a statement about the next few minutes, not
    /// about the task being finished — and repeating it does not change that.
    func testDuplicateAcknowledgementsNeverCompleteTheTask() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()
        let service = harness.followUp(at: now)

        let first = try await service.handle(
            outcome: .acknowledged,
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: plan.revision
        )
        let second = try await service.handle(
            outcome: .acknowledged,
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: plan.revision
        )

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)

        let stored = try await harness.repositories.tasks.task(id: task.id)
        XCTAssertNotEqual(stored?.status, .completed)
        XCTAssertNil(stored?.completedAt)
    }

    /// The claim survives the process. A callback answered before termination
    /// and re-delivered after relaunch finds the record already on disk — which
    /// is the whole reason this is persisted rather than held in memory.
    func testTheClaimIsHonouredByAFreshServiceInstance() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()

        _ = try await harness.followUp(at: now).handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: plan.revision
        )

        // A different `FollowUpService` over the same store: the app was
        // relaunched, and iOS is redelivering the response.
        let afterRelaunch = try await harness.followUp(at: now.addingTimeInterval(5)).handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: plan.revision
        )

        XCTAssertFalse(afterRelaunch.didChange)
        let storedPlan = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(storedPlan?.pendingStages.count, 1)
    }

    /// A claim is identified by (stage, action, revision). Two *different*
    /// actions on the same stage are two different claims, so dismissing and
    /// then finishing on the same notification sheet both land.
    func testDifferentActionsOnOneStageAreNotConfusedForDuplicates() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()
        let service = harness.followUp(at: now)

        _ = try await service.handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id
        )
        let done = try await service.handle(
            outcome: .completed,
            forTask: task.id,
            stageID: plan.stages[0].id
        )

        XCTAssertTrue(done.didChange)
        XCTAssertEqual(done.task.status, .completed)
        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 0)
    }

    func testTheHandledActionIdentityIsDerivedAndStable() {
        let stage = ReminderStage.ID()
        let task = TaskItem.ID()

        let first = HandledSupportAction(
            stageID: stage, taskID: task, action: "snoozed", revision: 3, handledAt: now
        )
        let again = HandledSupportAction(
            stageID: stage, taskID: task, action: "snoozed", revision: 3,
            handledAt: now.addingTimeInterval(600)
        )
        let laterRevision = HandledSupportAction(
            stageID: stage, taskID: task, action: "snoozed", revision: 4, handledAt: now
        )
        let otherAction = HandledSupportAction(
            stageID: stage, taskID: task, action: "dismissed", revision: 3, handledAt: now
        )

        // The time it happened is not part of the identity: the same answer,
        // redelivered later, is the same answer.
        XCTAssertEqual(first.id, again.id)
        // A new revision is genuinely a new question, so the answer is new too.
        XCTAssertNotEqual(first.id, laterRevision.id)
        XCTAssertNotEqual(first.id, otherAction.id)
    }

    // MARK: Stale callbacks

    /// Section 18 and 107. A notification that has been sitting on the lock
    /// screen since before the plan was recalculated, finally tapped. Applying
    /// it would resurrect a reminder that no longer exists.
    func testACallbackFromASupersededRevisionIsDeclined() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()
        let staleRevision = plan.revision

        // Something changed the plan — a snooze, a reschedule, a catch-up pass.
        var moved = plan
        moved.touch()
        moved.touch()
        try await harness.repositories.reminderPlans.save(moved)

        let result = try await harness.followUp(at: now).handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: staleRevision
        )

        XCTAssertFalse(result.didChange)
        XCTAssertNil(result.nextReminder)

        let stored = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(stored?.revision, moved.revision)
        XCTAssertEqual(stored?.stages.first?.state, plan.stages[0].state)
    }

    /// A callback with no revision at all — the app's own buttons, or a
    /// notification scheduled by a build that predates revisions — is accepted.
    /// Silently dropping every reminder in flight across an app update would be
    /// the worse failure.
    func testACallbackWithNoRevisionClaimIsAccepted() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()

        var moved = plan
        moved.touch()
        try await harness.repositories.reminderPlans.save(moved)

        let result = try await harness.followUp(at: now).handle(
            outcome: .dismissed,
            forTask: task.id,
            stageID: plan.stages[0].id,
            revision: nil
        )

        XCTAssertTrue(result.didChange)
    }

    /// Section 106. The 7:30 callback after a 7:20 completion.
    func testACallbackAfterCompletionSchedulesNothing() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()
        let service = harness.followUp(at: now)

        _ = try await service.handle(outcome: .completed, forTask: task.id)

        for outcome in [ReminderOutcome.dismissed, .missed, .snoozed(until: nil), .acknowledged] {
            let stale = try await service.handle(
                outcome: outcome,
                forTask: task.id,
                stageID: plan.stages[0].id
            )
            XCTAssertFalse(stale.didChange, "\(outcome) must not reopen a finished task")
            XCTAssertEqual(stale.task.status, .completed)
        }

        let outstanding = try await harness.platformRequestCount()
        XCTAssertEqual(outstanding, 0)
    }

    /// Section 67 and 68. A delivered notification is evidence that iOS showed
    /// something. It says nothing about whether the work got done, and clearing
    /// Notification Center says less than that.
    func testDeliveryAloneNeitherCompletesNorSchedules() async throws {
        let harness = Harness()
        let (task, plan) = try await harness.seed()

        let result = try await harness.followUp(at: now).handle(
            outcome: .delivered,
            forTask: task.id,
            stageID: plan.stages[0].id
        )

        XCTAssertNotEqual(result.task.status, .completed)
        XCTAssertNil(result.nextReminder)
        let stored = try await harness.repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(stored?.stages.first?.state, .delivered)
    }

    // MARK: Housekeeping

    /// The claim table has one job and must not grow without bound.
    func testOldClaimsArePruned() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let stage = ReminderStage.ID()
        let old = HandledSupportAction(
            stageID: stage,
            taskID: TaskItem.ID(),
            action: "dismissed",
            revision: 1,
            handledAt: now.addingTimeInterval(-TimeSpan.days(90))
        )
        let recent = HandledSupportAction(
            stageID: ReminderStage.ID(),
            taskID: TaskItem.ID(),
            action: "dismissed",
            revision: 1,
            handledAt: now
        )

        _ = try await repositories.supportActions.claim(old)
        _ = try await repositories.supportActions.claim(recent)

        try await repositories.supportActions.prune(
            before: now.addingTimeInterval(-TimeSpan.days(30))
        )

        let oldSurvives = try await repositories.supportActions.wasHandled(old.id)
        let recentSurvives = try await repositories.supportActions.wasHandled(recent.id)
        XCTAssertFalse(oldSurvives)
        XCTAssertTrue(recentSurvives)
    }

    // MARK: Harness

    private struct Harness {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()

        func followUp(at date: Date) -> FollowUpService {
            FollowUpService(
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

        /// A task that has just been reminded about, and the reminder that did
        /// it. Normal importance, so the follow-up ladder stays on the ordinary
        /// notification channel rather than jumping to an alarm.
        func seed() async throws -> (TaskItem, ReminderPlan) {
            var task = TaskItem(
                title: "Pay the electricity bill",
                status: .reminded,
                importance: .normal,
                createdAt: Date(timeIntervalSince1970: 1_759_000_000)
            )
            let stage = ReminderStage(
                kind: .finalCall,
                offset: .absolute(Date(timeIntervalSince1970: 1_760_000_000)),
                message: "Pay the electricity bill",
                requiresConfirmation: true,
                state: .delivered,
                stateChangedAt: Date(timeIntervalSince1970: 1_760_000_000),
                scheduledFor: Date(timeIntervalSince1970: 1_760_000_000)
            )
            let plan = ReminderPlan(
                subject: ReminderSubject(
                    reference: .task(task.id),
                    title: task.title,
                    anchor: .unscheduled,
                    importance: .normal
                ),
                stages: [stage],
                createdAt: Date(timeIntervalSince1970: 1_759_000_000),
                generatedBy: "test"
            )
            task.reminderPlanID = plan.id
            try await repositories.reminderPlans.save(plan)
            try await repositories.tasks.save(task)
            return (task, plan)
        }
    }
}
