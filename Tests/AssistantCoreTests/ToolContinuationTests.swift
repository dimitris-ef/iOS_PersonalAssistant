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

    func testStopsAtTheRoundLimitEvenIfTheModelKeepsCallingTools() async throws {
        // A model that never stops proposing actions must not loop forever.
        let provider = ScriptedRoundsProvider(
            id: "test.looping",
            supportsContinuation: true,
            rounds: [
                .init(text: "", toolCalls: [try memoryCall()]),
                .init(text: "", toolCalls: [try memoryCall()]),
                .init(text: "", toolCalls: [try memoryCall()]),
                .init(text: "", toolCalls: [try memoryCall()]),
            ]
        )
        let (engine, repositories, conversationID) = try await makeEngine(provider: provider)

        let result = try await engine.send("Remember that", in: conversationID)

        // The default maximumToolRounds is 2.
        XCTAssertEqual(provider.requestCount, 2)
        // Both rounds really executed — this is the evidence the loop ran
        // twice, and it is what the memory count used to stand in for.
        XCTAssertEqual(result.plan.actions.count, 2)

        // But only one memory exists. Both rounds proposed the *same* content,
        // and since `storeMemory` began going through `MemoryService` an
        // identical write is recognised as a duplicate and folded into the
        // existing record rather than added beside it. Two stored memories
        // here would now be the bug.
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
        XCTAssertEqual(result.assistantMessage.text, "Working on it.")
        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1)
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

// MARK: - Stub

/// Replays a scripted sequence of responses, one per round.
private final class ScriptedRoundsProvider: AIProvider, @unchecked Sendable {
    struct Round {
        let text: String
        let toolCalls: [AIToolCall]
    }

    let metadata: AIProviderMetadata
    private let rounds: [Round]
    private let failAfterRounds: Int?
    private let lock = NSLock()
    private var calls = 0
    private var requests: [AIRequest] = []

    init(
        id: AIProviderIdentifier,
        supportsContinuation: Bool,
        rounds: [Round],
        failAfterRounds: Int? = nil
    ) {
        self.metadata = AIProviderMetadata(
            id: id,
            displayName: "Scripted \(id)",
            kind: .development,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 10,
            supportsToolResultContinuation: supportsContinuation
        )
        self.rounds = rounds
        self.failAfterRounds = failAfterRounds
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var receivedRequests: [AIRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func availability() async -> AIProviderAvailability { .available }

    func availableModels() async throws -> [AIModel] { [] }

    func respond(to request: AIRequest) async throws -> AIResponse {
        lock.lock()
        let index = calls
        calls += 1
        requests.append(request)
        let shouldFail = failAfterRounds.map { index >= $0 } ?? false
        lock.unlock()

        if shouldFail {
            throw AIProviderError.transport("scripted failure")
        }

        let round = rounds[min(index, rounds.count - 1)]
        return AIResponse(
            text: round.text,
            toolCalls: round.toolCalls,
            stopReason: round.toolCalls.isEmpty ? .endTurn : .toolCalls,
            providerID: metadata.id
        )
    }
}
