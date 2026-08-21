import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import MockPlatform
import XCTest
@testable import AssistantCore

/// The bounded tool-result round.
///
/// A provider that can read tool results gets shown what its actions did and
/// asked for a closing reply. A provider that cannot gets exactly one round —
/// which is what stops it being re-asked the same question and duplicating the
/// actions it already proposed.
final class ToolContinuationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEngine(provider: any AIProvider) async throws -> (AssistantEngine, AssistantRepositories, Conversation.ID) {
        let repositories = AssistantRepositories.ephemeral()
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = provider.metadata.id
        try await repositories.settings.update(settings)

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [provider]),
            repositories: repositories,
            services: PlatformServices.mock(),
            dateProvider: FixedDateProvider(now: now)
        )
        let conversation = try await engine.startConversation()
        return (engine, repositories, conversation.id)
    }

    private func memoryCall() throws -> AIToolCall {
        try ToolCallFactory.make(
            .storeMemory,
            StoreMemoryInput(content: "Needs 45 minutes to get ready", kind: .routine)
        )
    }

    // MARK: Continuation

    func testShowsToolResultsToAProviderThatCanReadThem() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.continuing",
            supportsContinuation: true,
            rounds: [
                .init(text: "", toolCalls: [try memoryCall()]),
                .init(text: "Noted — I've saved that.", toolCalls: []),
            ]
        )
        let (engine, repositories, conversationID) = try await makeEngine(provider: provider)

        let result = try await engine.send("Remember that", in: conversationID)

        // Two rounds: propose, then summarise.
        XCTAssertEqual(provider.requestCount, 2)

        // The closing reply is what the user sees, not the empty first turn.
        XCTAssertEqual(result.assistantMessage.text, "Noted — I've saved that.")

        // The action ran exactly once.
        XCTAssertEqual(result.plan.actions.map(\.kind), [.storeMemory])
        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1)

        // The second request carried the assistant's tool calls and the result.
        let followUp = try XCTUnwrap(provider.receivedRequests.last)
        let assistantMessage = try XCTUnwrap(
            followUp.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistantMessage.toolCalls.count, 1)

        let toolMessage = try XCTUnwrap(followUp.messages.last(where: { $0.role == .tool }))
        XCTAssertEqual(toolMessage.toolCallID, assistantMessage.toolCalls.first?.id)
        XCTAssertTrue(toolMessage.content.contains("Remembered"))
    }

    func testGivesOneRoundToAProviderThatCannotReadToolResults() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.single-round",
            supportsContinuation: false,
            rounds: [
                .init(text: "Saving that.", toolCalls: [try memoryCall()]),
                // Would duplicate the action if the engine asked again.
                .init(text: "Saving that.", toolCalls: [try memoryCall()]),
            ]
        )
        let (engine, repositories, conversationID) = try await makeEngine(provider: provider)

        let result = try await engine.send("Remember that", in: conversationID)

        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(result.plan.actions.count, 1)

        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1, "One round means one memory, not two")
    }

    func testAModelThatKeepsProposingTheSameActionIsStopped() async throws {
        // A model that never stops proposing actions must not loop forever, and
        // must not do the action again each time round.
        let provider = ScriptedRoundsProvider(
            id: "test.looping",
            supportsContinuation: true,
            rounds: [
                .init(toolCalls: [try memoryCall()]),
                .init(toolCalls: [try memoryCall()]),
                .init(toolCalls: [try memoryCall()]),
                .init(toolCalls: [try memoryCall()]),
                .init(toolCalls: [try memoryCall()]),
                .init(toolCalls: [try memoryCall()]),
                .init(toolCalls: [try memoryCall()]),
            ]
        )
        let (engine, repositories, conversationID) = try await makeEngine(provider: provider)

        let result = try await engine.send("Remember that", in: conversationID)

        // Stated as the rule rather than as a number, so tightening a limit
        // does not silently make this test about nothing.
        XCTAssertLessThanOrEqual(provider.requestCount, AgentLimits.default.maximumRounds)
        XCTAssertEqual(result.diagnostics.stopReason, .repeatedProposals)

        // Only the first round produced an action at all: every later proposal
        // was recognised as the same call and answered with the first result.
        XCTAssertEqual(result.plan.actions.count, 1)
        XCTAssertGreaterThan(result.diagnostics.duplicateCount, 0)

        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1)
    }

    func testKeepsCompletedActionsWhenTheClosingRequestFails() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.failing-followup",
            supportsContinuation: true,
            rounds: [.init(text: "Working on it.", toolCalls: [try memoryCall()])],
            failAfterRounds: 1
        )
        let (engine, repositories, conversationID) = try await makeEngine(provider: provider)

        let result = try await engine.send("Remember that", in: conversationID)

        // The follow-up failed, but the action already happened and the turn
        // still reports it rather than throwing the work away.
        XCTAssertEqual(result.plan.actions.count, 1)
        XCTAssertEqual(result.diagnostics.stopReason, .providerFailed)
        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1)

        // What the user is told is *not* "Working on it." — that sentence was
        // written before the tool ran and describes an intention, not a result.
        // The deterministic summary replaces it and says what really happened.
        XCTAssertNotEqual(result.assistantMessage.text, "Working on it.")
        XCTAssertTrue(result.assistantMessage.text.contains("storeMemory"))
    }

    func testRejectedToolCallsAreReportedBackToTheModel() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.rejecting",
            supportsContinuation: true,
            rounds: [
                .init(
                    text: "",
                    toolCalls: [
                        AIToolCall(name: "notARealTool", arguments: .object([:])),
                        try memoryCall(),
                    ]
                ),
                .init(text: "Done.", toolCalls: []),
            ]
        )
        let (engine, _, conversationID) = try await makeEngine(provider: provider)

        let result = try await engine.send("Do something", in: conversationID)

        // The unknown tool is rejected, and only the valid one runs.
        XCTAssertEqual(result.plan.rejected.map(\.name), ["notARealTool"])
        XCTAssertEqual(result.plan.actions.map(\.kind), [.storeMemory])

        // The model is told why, so it can correct itself — it still cannot
        // bypass the rejection.
        let followUp = try XCTUnwrap(provider.receivedRequests.last)
        let toolMessages = followUp.messages.filter { $0.role == .tool }
        XCTAssertTrue(toolMessages.contains { $0.content.contains("Rejected") })
    }
}
