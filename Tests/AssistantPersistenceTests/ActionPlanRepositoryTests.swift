import AssistantDomain
import AssistantPersistence
import AssistantTools
import XCTest

/// The snapshot backend's half of the action-plan contract.
///
/// The SwiftData implementation has its own tests. These exist so the two
/// cannot drift: a repository swap is supposed to be invisible, and it only
/// stays invisible if both sides are held to the same behaviour.
final class ActionPlanRepositoryTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_760_000_000)

    func testStoresAndReturnsAPlan() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let conversationID = Conversation.ID()
        let (plan, results) = makePlan()

        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: plan, results: results, conversationID: conversationID)
        )

        let loaded = try await repositories.actionPlans.record(id: plan.id)
        let record = try XCTUnwrap(loaded)
        XCTAssertEqual(record.plan.id, plan.id)
        XCTAssertEqual(record.plan.actions.map(\.id), plan.actions.map(\.id))
        XCTAssertEqual(record.results.map(\.id), results.map(\.id))
        XCTAssertEqual(record.conversationID, conversationID)
    }

    func testTypedRequestsSurviveTheRoundTrip() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let conversationID = Conversation.ID()
        let action = AssistantAction(
            request: .createTask(
                CreateTaskInput(title: "Call the dentist", importance: .high)
            ),
            origin: .model,
            authorization: .allowed
        )
        let plan = AssistantActionPlan(actions: [action], createdAt: referenceDate)

        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: plan, results: [], conversationID: conversationID)
        )

        let loaded = try await repositories.actionPlans.record(id: plan.id)
        let record = try XCTUnwrap(loaded)
        guard case .createTask(let input) = try XCTUnwrap(record.plan.actions.first).request else {
            return XCTFail("Expected a createTask request")
        }
        XCTAssertEqual(input.title, "Call the dentist")
        XCTAssertEqual(input.importance, .high)
    }

    func testListsOnlyThePlansOfOneConversationOldestFirst() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let mine = Conversation.ID()
        let other = Conversation.ID()

        let older = AssistantActionPlan(actions: [], createdAt: referenceDate)
        let newer = AssistantActionPlan(actions: [], createdAt: referenceDate.addingTimeInterval(60))
        let elsewhere = AssistantActionPlan(actions: [], createdAt: referenceDate)

        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: newer, results: [], conversationID: mine)
        )
        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: older, results: [], conversationID: mine)
        )
        try await repositories.actionPlans.save(
            ActionPlanRecord(plan: elsewhere, results: [], conversationID: other)
        )

        let records = try await repositories.actionPlans.records(inConversation: mine)
        XCTAssertEqual(records.map(\.plan.id), [older.id, newer.id])
    }

    func testSavingTwiceKeepsOneRecord() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let conversationID = Conversation.ID()
        let (plan, results) = makePlan()
        let record = ActionPlanRecord(plan: plan, results: results, conversationID: conversationID)

        try await repositories.actionPlans.save(record)
        try await repositories.actionPlans.save(record)

        let all = try await repositories.actionPlans.records(inConversation: conversationID)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.plan.actions.count, 1)
    }

    func testAnUnknownPlanIsNil() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let loaded = try await repositories.actionPlans.record(id: ActionPlanID())
        XCTAssertNil(loaded)
    }

    private func makePlan() -> (AssistantActionPlan, [ToolResult]) {
        let action = AssistantAction(
            request: .storeMemory(StoreMemoryInput(content: "remember", kind: .fact)),
            origin: .model,
            authorization: .allowed
        )
        let plan = AssistantActionPlan(actions: [action], createdAt: referenceDate)
        let result = ToolResult(
            actionID: action.id,
            kind: .storeMemory,
            outcome: .simulated(platform: "MockNotifications"),
            message: "Remembered",
            producedAt: referenceDate
        )
        return (plan, [result])
    }
}
