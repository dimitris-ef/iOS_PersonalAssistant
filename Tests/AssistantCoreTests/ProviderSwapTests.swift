import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import MockPlatform
import XCTest
@testable import AssistantCore

/// The architectural promise: the AI model is an interchangeable reasoning
/// engine. Switching it must not cost the user anything they own.
final class ProviderSwapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSwitchingProvidersKeepsConversationsMemoriesTasksAndSettings() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let dateProvider = FixedDateProvider(now: now)

        let memoryCall = try ToolCallFactory.make(
            .storeMemory,
            StoreMemoryInput(content: "Needs 30 minutes to get ready", kind: .routine)
        )
        let taskCall = try ToolCallFactory.make(
            .createTask,
            CreateTaskInput(title: "Pay the electricity bill", dueDate: now.addingTimeInterval(Duration.days(4)))
        )

        let onDevice = StubAIProvider(
            id: "test.on-device",
            responses: [
                AIResponse(
                    text: "Noted.",
                    toolCalls: [memoryCall, taskCall],
                    stopReason: .toolCalls,
                    providerID: "test.on-device"
                )
            ]
        )
        let remote = StubAIProvider(
            id: "test.remote",
            responses: [
                AIResponse(text: "Still here.", providerID: "test.remote")
            ]
        )

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = onDevice.metadata.id
        settings.routingPolicy = .explicit
        settings.support.advanceNoticeDays = [5]
        try await repositories.settings.update(settings)

        let registry = AIProviderRegistry(providers: [onDevice, remote])
        let engine = AssistantEngine(
            providers: registry,
            repositories: repositories,
            services: services,
            dateProvider: dateProvider
        )

        // Turn one, on the first provider.
        let conversation = try await engine.startConversation(title: "Shared")
        let first = try await engine.send("Remember how long I need", in: conversation.id)
        XCTAssertEqual(first.providerID, "test.on-device")

        let memoriesBefore = try await repositories.memories.all()
        let tasksBefore = try await repositories.tasks.tasks(matching: .outstanding)
        XCTAssertEqual(memoriesBefore.count, 1)
        XCTAssertEqual(tasksBefore.count, 1)

        // Switch the model. Nothing else changes.
        var switched = try await repositories.settings.settings()
        switched.preferredProviderID = remote.metadata.id
        try await repositories.settings.update(switched)

        let second = try await engine.send("Anything else?", in: conversation.id)
        XCTAssertEqual(second.providerID, "test.remote")

        // Conversation history carried over, including both turns.
        XCTAssertEqual(second.conversation.messages.count, 4)
        XCTAssertEqual(second.conversation.messages.first?.text, "Remember how long I need")

        // Memories, tasks and settings are untouched by the swap.
        let memoriesAfter = try await repositories.memories.all()
        let tasksAfter = try await repositories.tasks.tasks(matching: .outstanding)
        XCTAssertEqual(memoriesAfter.map(\.content), memoriesBefore.map(\.content))
        XCTAssertEqual(tasksAfter.map(\.id), tasksBefore.map(\.id))

        let settingsAfter = try await repositories.settings.settings()
        XCTAssertEqual(settingsAfter.support.advanceNoticeDays, [5])

        // The new provider was handed the same context and the same tools.
        let remotePrompt = try XCTUnwrap(remote.lastSystemPrompt)
        XCTAssertTrue(remotePrompt.contains("Needs 30 minutes to get ready"))
        XCTAssertTrue(remotePrompt.contains("Pay the electricity bill"))

        let remoteRequest = try XCTUnwrap(remote.receivedRequests.last)
        let onDeviceRequest = try XCTUnwrap(onDevice.receivedRequests.last)
        XCTAssertEqual(
            Set(remoteRequest.tools.map(\.name)),
            Set(onDeviceRequest.tools.map(\.name)),
            "The tool catalogue belongs to the app, not to a provider"
        )
        XCTAssertEqual(Set(remoteRequest.tools.map(\.name)), Set(ToolKind.allCases.map(\.rawValue)))
    }

    func testRoutingFallsBackWhenThePreferredProviderIsUnavailable() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let unavailable = UnavailableProvider(id: "apple.foundation-models")
        let usable = StubAIProvider(id: "test.fallback", text: "Fallback here.")

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = unavailable.metadata.id
        settings.routingPolicy = .preferOnDevice
        try await repositories.settings.update(settings)

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [unavailable, usable]),
            repositories: repositories,
            services: PlatformServices.mock(),
            dateProvider: FixedDateProvider(now: now)
        )
        let conversation = try await engine.startConversation()

        let result = try await engine.send("Hello", in: conversation.id)

        XCTAssertEqual(result.providerID, "test.fallback")
        XCTAssertEqual(result.assistantMessage.text, "Fallback here.")
    }

    func testExplicitRoutingRefusesToSilentlySubstituteAnotherModel() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let unavailable = UnavailableProvider(id: "apple.foundation-models")
        let other = StubAIProvider(id: "test.other")

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = unavailable.metadata.id
        settings.routingPolicy = .explicit
        try await repositories.settings.update(settings)

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [unavailable, other]),
            repositories: repositories,
            services: PlatformServices.mock(),
            dateProvider: FixedDateProvider(now: now)
        )
        let conversation = try await engine.startConversation()

        do {
            _ = try await engine.send("Hello", in: conversation.id)
            XCTFail("Expected explicit routing to fail rather than switch models")
        } catch let error as ModelRoutingError {
            guard case .explicitProviderUnavailable(let id, _) = error else {
                return XCTFail("Unexpected routing error: \(error)")
            }
            XCTAssertEqual(id, "apple.foundation-models")
        }
    }
}
