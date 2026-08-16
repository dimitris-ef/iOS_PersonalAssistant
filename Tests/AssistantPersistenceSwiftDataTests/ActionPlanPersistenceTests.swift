#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import AssistantTools
import SwiftData
import XCTest

/// The structured content under an assistant reply.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class ActionPlanPersistenceTests: PersistenceTestCase {

    func testAnExecutedPlanSurvivesARelaunch() async throws {
        let conversation = try await makeConversation()
        let (plan, results) = makePlan()

        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: plan, results: results, conversationID: conversation.id)
        )

        try relaunch()

        let loaded = try await repositories.actionPlans.record(id: plan.id)
        let record = try XCTUnwrap(loaded)
        XCTAssertEqual(record.plan.id, plan.id)
        XCTAssertEqual(record.plan.actions.count, 2)
        XCTAssertEqual(record.results.count, 2)
        XCTAssertEqual(record.conversationID, conversation.id)
    }

    /// The typed request has to come back typed.
    ///
    /// The transcript builds its cards by switching on `ToolRequest` — an event
    /// card needs the title, the start date and the location. If the payload
    /// came back as an opaque string the card would degrade to a generic row
    /// and the conversation would quietly lose detail.
    func testTheToolRequestComesBackFullyTyped() async throws {
        let conversation = try await makeConversation()
        let start = Self.referenceDate.addingTimeInterval(TimeSpan.days(2))
        let action = AssistantAction(
            request: .createCalendarEvent(
                CreateCalendarEventInput(
                    eventID: CalendarItem.ID(),
                    title: "Haircut",
                    start: start,
                    end: start.addingTimeInterval(1_800),
                    location: "Kolonaki",
                    importance: .high,
                    travelDurationMinutes: 20,
                    preparationDurationMinutes: 30
                )
            ),
            origin: .model,
            authorization: .allowed
        )
        let plan = AssistantActionPlan(actions: [action], createdAt: Self.referenceDate)

        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: plan, results: [], conversationID: conversation.id)
        )

        try relaunch()

        let loaded = try await repositories.actionPlans.record(id: plan.id)
        let record = try XCTUnwrap(loaded)
        guard case .createCalendarEvent(let input) = try XCTUnwrap(record.plan.actions.first).request else {
            return XCTFail("Expected a createCalendarEvent request")
        }
        XCTAssertEqual(input.title, "Haircut")
        XCTAssertEqual(input.location, "Kolonaki")
        XCTAssertEqual(input.start, start)
        XCTAssertEqual(input.importance, .high)
    }

    /// Honesty has to survive a reload.
    ///
    /// A card produced by a mock service is badged "simulated — nothing was
    /// scheduled on this device". If the outcome came back as `.executed`, a
    /// reopened transcript would start claiming the phone did something it
    /// never did.
    func testASimulatedOutcomeIsStillSimulatedAfterReloading() async throws {
        let conversation = try await makeConversation()
        let action = AssistantAction(
            request: .storeMemory(
                StoreMemoryInput(content: "remember this", kind: .fact, tags: [], salience: 0.5)
            ),
            origin: .model,
            authorization: .allowed
        )
        let plan = AssistantActionPlan(actions: [action], createdAt: Self.referenceDate)
        let result = ToolResult(
            actionID: action.id,
            kind: .storeMemory,
            outcome: .simulated(platform: "MockNotifications"),
            message: "Notification scheduled",
            producedAt: Self.referenceDate
        )

        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: plan, results: [result], conversationID: conversation.id)
        )

        try relaunch()

        let loaded = try await repositories.actionPlans.record(id: plan.id)
        let record = try XCTUnwrap(loaded)
        guard case .simulated(let platform) = try XCTUnwrap(record.results.first).outcome else {
            return XCTFail("A simulated action must not come back as executed")
        }
        XCTAssertEqual(platform, "MockNotifications")
    }

    func testEveryOutcomeCaseRoundTrips() async throws {
        let conversation = try await makeConversation()
        let outcomes: [ToolOutcome] = [
            .executed,
            .simulated(platform: "MockCalendar"),
            .awaitingConfirmation,
            .denied(reason: "not allowed"),
            .failed(reason: "the service was unreachable"),
            .unsupported(reason: "not built yet"),
        ]

        for outcome in outcomes {
            let action = AssistantAction(
                request: .completeTask(CompleteTaskInput(taskID: TaskItem.ID())),
                origin: .model,
                authorization: .allowed
            )
            let plan = AssistantActionPlan(actions: [action], createdAt: Self.referenceDate)
            let result = ToolResult(
                actionID: action.id,
                kind: .completeTask,
                outcome: outcome,
                message: "m",
                producedAt: Self.referenceDate
            )
            try await repositories.actionPlans.save(
                ActionPlanRecord(plan: plan, results: [result], conversationID: conversation.id)
            )

            let loaded = try await repositories.actionPlans.record(id: plan.id)
            let record = try XCTUnwrap(loaded)
            XCTAssertEqual(record.results.first?.outcome, outcome)
        }
    }

    func testPlansAreListedForTheirConversationOldestFirst() async throws {
        let conversation = try await makeConversation()
        let other = Conversation(title: "Other", createdAt: Self.referenceDate)
        try await repositories.conversations.save(other)

        let first = AssistantActionPlan(actions: [], createdAt: Self.referenceDate)
        let second = AssistantActionPlan(
            actions: [],
            createdAt: Self.referenceDate.addingTimeInterval(60)
        )
        let elsewhere = AssistantActionPlan(actions: [], createdAt: Self.referenceDate)

        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: second, results: [], conversationID: conversation.id)
        )
        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: first, results: [], conversationID: conversation.id)
        )
        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: elsewhere, results: [], conversationID: other.id)
        )

        try relaunch()

        let records = try await repositories.actionPlans.records(inConversation: conversation.id)
        XCTAssertEqual(records.map(\.plan.id), [first.id, second.id])
    }

    /// Action history belongs to its conversation and goes with it.
    func testDeletingAConversationRemovesItsActionPlans() async throws {
        let conversation = try await makeConversation()
        let (plan, results) = makePlan()
        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: plan, results: results, conversationID: conversation.id)
        )

        try await repositories.conversations.delete(id: conversation.id)
        try relaunch()

        let loaded = try await repositories.actionPlans.record(id: plan.id)
        XCTAssertNil(loaded)

        let persistence = AssistantPersistenceActor(modelContainer: store.container)
        let leftovers = try await persistence.read { context in
            [
                try context.fetchCount(FetchDescriptor<SDActionPlan>()),
                try context.fetchCount(FetchDescriptor<SDAction>()),
                try context.fetchCount(FetchDescriptor<SDToolResult>()),
            ]
        }
        XCTAssertEqual(leftovers, [0, 0, 0], "no orphaned action rows may remain")
    }

    func testSavingTheSamePlanTwiceDoesNotDuplicateItsCards() async throws {
        let conversation = try await makeConversation()
        let (plan, results) = makePlan()
        let record = ActionPlanRecord(
            plan: plan,
            results: results,
            conversationID: conversation.id
        )

        try await repositories.actionPlans.save(record)
        try await repositories.actionPlans.save(record)

        try relaunch()

        let row = try await repositories.actionPlans.record(id: plan.id)
        let reloaded = try XCTUnwrap(row)
        XCTAssertEqual(reloaded.plan.actions.count, 2)
        XCTAssertEqual(reloaded.results.count, 2)
        let plansForConversation = try await repositories.actionPlans
            .records(inConversation: conversation.id)
        XCTAssertEqual(plansForConversation.count, 1)
    }

    // MARK: Fixtures

    private func makeConversation() async throws -> Conversation {
        let conversation = Conversation(title: "Assistant", createdAt: Self.referenceDate)
        try await repositories.conversations.save(conversation)
        return conversation
    }

    private func makePlan() -> (AssistantActionPlan, [ToolResult]) {
        let memoryAction = AssistantAction(
            request: .storeMemory(
                StoreMemoryInput(
                    content: "Thirty minutes to get ready",
                    kind: .routine,
                    tags: ["morning"],
                    salience: 0.8
                )
            ),
            origin: .model,
            authorization: .allowed
        )
        let notificationAction = AssistantAction(
            request: .scheduleNotification(
                ScheduleNotificationInput(
                    title: "Start getting ready",
                    body: "Your haircut is in an hour.",
                    fireDate: Self.referenceDate.addingTimeInterval(3_600),
                    escalation: .standard,
                    requiresCompletionConfirmation: true,
                    stageID: ReminderStage.ID()
                )
            ),
            origin: .supportPlanner,
            authorization: .allowed,
            rationale: "preparation reminder for Haircut"
        )

        let plan = AssistantActionPlan(
            actions: [memoryAction, notificationAction],
            createdAt: Self.referenceDate
        )
        let results = [
            ToolResult(
                actionID: memoryAction.id,
                kind: .storeMemory,
                outcome: .executed,
                message: "Remembered",
                producedAt: Self.referenceDate
            ),
            ToolResult(
                actionID: notificationAction.id,
                kind: .scheduleNotification,
                outcome: .simulated(platform: "MockNotifications"),
                message: "Notification scheduled",
                producedAt: Self.referenceDate
            ),
        ]
        return (plan, results)
    }
}

#endif
