#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import XCTest

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class ReminderPlanPersistenceTests: PersistenceTestCase {

    func testSavesAPlanWithAllOfItsStages() async throws {
        let plan = makePlan()
        try await repositories.reminderPlans.save(plan)

        try relaunch()

        let stored = try await repositories.reminderPlans.plan(id: plan.id)
        let loaded = try XCTUnwrap(stored)
        // The whole plan, compared whole: the multi-stage shape is the support
        // strategy, and a plan that came back as one date would be a different
        // product.
        XCTAssertEqual(loaded, plan)
        XCTAssertEqual(loaded.stages.count, 5)
        XCTAssertEqual(
            loaded.stages.map(\.kind),
            [.advanceNotice, .morningOf, .preparation, .leave, .finalCall]
        )
    }

    func testStageOrderIsStable() async throws {
        let plan = makePlan()
        try await repositories.reminderPlans.save(plan)

        try relaunch()

        let stored = try await repositories.reminderPlans.plan(id: plan.id)
        let loaded = try XCTUnwrap(stored)
        XCTAssertEqual(loaded.stages.map(\.id), plan.stages.map(\.id))
    }

    func testRoundTripsEveryOffsetCase() async throws {
        let offsets: [ReminderOffset] = [
            .beforeAnchor(TimeSpan.minutes(30)),
            .afterAnchor(TimeSpan.hours(1)),
            .daysBefore(3, at: TimeOfDay(hour: 9, minute: 15)),
            .morningOf(TimeOfDay(hour: 8)),
            .absolute(Self.referenceDate),
        ]

        for offset in offsets {
            let plan = makePlan(stages: [
                ReminderStage(kind: .nudge, offset: offset, message: "m")
            ])
            try await repositories.reminderPlans.save(plan)
            let stored = try await repositories.reminderPlans.plan(id: plan.id)
            let loaded = try XCTUnwrap(stored)
            XCTAssertEqual(loaded.stages.first?.offset, offset)
        }
    }

    func testRoundTripsEveryAnchorCase() async throws {
        let window = TimeWindow(
            start: Self.referenceDate,
            end: Self.referenceDate.addingTimeInterval(TimeSpan.days(2))
        )
        let anchors: [ReminderAnchor] = [
            .moment(Self.referenceDate),
            .deadline(Self.referenceDate.addingTimeInterval(600)),
            .window(window),
            .unscheduled,
        ]

        for anchor in anchors {
            let plan = makePlan(anchor: anchor)
            try await repositories.reminderPlans.save(plan)
            let stored = try await repositories.reminderPlans.plan(id: plan.id)
            let loaded = try XCTUnwrap(stored)
            XCTAssertEqual(loaded.subject.anchor, anchor)
        }
    }

    func testPoliciesSurvive() async throws {
        let plan = makePlan(
            followUp: FollowUpPolicy(
                isEnabled: true,
                maximumFollowUps: 5,
                interval: TimeSpan.minutes(45),
                escalatesEachTime: false
            ),
            snooze: SnoozePolicy(
                isAllowed: false,
                defaultDuration: TimeSpan.minutes(7),
                maximumSnoozes: 1,
                escalateAfterSnoozes: 1
            ),
            completion: CompletionPolicy(
                requiresExplicitConfirmation: true,
                markMissedAfter: TimeSpan.hours(3)
            )
        )
        try await repositories.reminderPlans.save(plan)

        try relaunch()

        let stored = try await repositories.reminderPlans.plan(id: plan.id)
        let loaded = try XCTUnwrap(stored)
        XCTAssertEqual(loaded.followUp.maximumFollowUps, 5)
        XCTAssertFalse(loaded.snooze.isAllowed)
        // The rule the whole reminder architecture rests on.
        XCTAssertTrue(loaded.completion.requiresExplicitConfirmation)
        XCTAssertEqual(loaded.completion.markMissedAfter, TimeSpan.hours(3))
    }

    func testFindsPlansByTheirSubject() async throws {
        let taskID = TaskItem.ID()
        let eventID = CalendarItem.ID()

        let taskPlan = makePlan(reference: .task(taskID))
        let eventPlan = makePlan(reference: .calendarItem(eventID))
        let looseplan = makePlan(reference: .freeform("water the plants"))
        for plan in [taskPlan, eventPlan, looseplan] {
            try await repositories.reminderPlans.save(plan)
        }

        try relaunch()

        let byTask = try await repositories.reminderPlans.plans(for: .task(taskID))
        XCTAssertEqual(byTask.map(\.id), [taskPlan.id])

        let byEvent = try await repositories.reminderPlans.plans(for: .calendarItem(eventID))
        XCTAssertEqual(byEvent.map(\.id), [eventPlan.id])

        let byText = try await repositories.reminderPlans.plans(for: .freeform("water the plants"))
        XCTAssertEqual(byText.map(\.id), [looseplan.id])
    }

    func testUpdatingAPlanReplacesItsStagesWithoutDuplicating() async throws {
        var plan = makePlan()
        try await repositories.reminderPlans.save(plan)

        plan.stages.removeLast()
        plan.stages[0].message = "Rewritten"
        try await repositories.reminderPlans.save(plan)

        try relaunch()

        let stored = try await repositories.reminderPlans.plan(id: plan.id)
        let loaded = try XCTUnwrap(stored)
        XCTAssertEqual(loaded.stages.count, 4)
        XCTAssertEqual(loaded.stages.first?.message, "Rewritten")
    }

    // MARK: Fixtures

    private func makePlan(
        reference: ReminderSubject.Reference = .task(TaskItem.ID()),
        anchor: ReminderAnchor = .moment(Date(timeIntervalSince1970: 1_760_100_000)),
        stages: [ReminderStage]? = nil,
        followUp: FollowUpPolicy = FollowUpPolicy(),
        snooze: SnoozePolicy = SnoozePolicy(),
        completion: CompletionPolicy = CompletionPolicy()
    ) -> ReminderPlan {
        ReminderPlan(
            subject: ReminderSubject(
                reference: reference,
                title: "Haircut",
                anchor: anchor,
                importance: .high,
                preparationDuration: TimeSpan.minutes(30),
                travelDuration: TimeSpan.minutes(20),
                isTimeFixed: true
            ),
            stages: stages ?? defaultStages,
            followUp: followUp,
            snooze: snooze,
            completion: completion,
            createdAt: Self.referenceDate,
            generatedBy: "test"
        )
    }

    private var defaultStages: [ReminderStage] {
        [
            ReminderStage(
                kind: .advanceNotice,
                offset: .daysBefore(3, at: TimeOfDay(hour: 9)),
                message: "Your haircut is in three days."
            ),
            ReminderStage(
                kind: .morningOf,
                offset: .morningOf(TimeOfDay(hour: 8)),
                message: "You have a haircut today."
            ),
            ReminderStage(
                kind: .preparation,
                offset: .beforeAnchor(TimeSpan.minutes(50)),
                message: "Start getting ready.",
                requiresConfirmation: true
            ),
            ReminderStage(
                kind: .leave,
                offset: .beforeAnchor(TimeSpan.minutes(20)),
                channel: .alarm,
                escalation: .insistent,
                message: "Leave now.",
                requiresConfirmation: true
            ),
            ReminderStage(
                kind: .finalCall,
                offset: .beforeAnchor(TimeSpan.minutes(10)),
                message: "Starting in ten minutes."
            ),
        ]
    }
}

#endif
