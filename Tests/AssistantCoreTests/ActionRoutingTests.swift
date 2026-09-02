import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import MockPlatform
import XCTest

@testable import AssistantCore

/// Routing, through the real engine.
///
/// ## The architecture this proves
///
/// Before this part, setting a reminder worked or did not depending on which
/// model the user had picked to talk to. A chat-only selection meant the phone
/// could not be operated; picking a different chat model changed what the app
/// could *do*.
///
/// These tests assert the separation from the outside: which provider was
/// invoked for which message, and — the two that matter most — that the chat
/// model is never asked to interpret an action, and never quietly asked to
/// answer one the action system could not run.
final class ActionRoutingTests: XCTestCase {

    /// 31 August 2026, 14:20, Europe/Athens.
    private let now = Date(timeIntervalSince1970: 1_788_175_200)
    private let athens = TimeZone(identifier: "Europe/Athens")!

    // MARK: Doubles

    /// An action backend that answers from a script and counts its calls.
    private actor ScriptedActionBackend: ActionModelProvider {
        nonisolated let id: String
        private let state: ActionModelAvailability
        private let result: Result<LocalSemanticActionResult, ActionModelError>
        private(set) var callCount = 0
        private(set) var categories: [LocalActionCategory] = []
        private(set) var constrained: [ActionGenerationConstraints] = []

        init(
            id: String = "test.action-backend",
            availability: ActionModelAvailability = .available,
            result: Result<LocalSemanticActionResult, ActionModelError> = .success(
                .action(
                    LocalSemanticAction(
                        intent: .reminderCreate,
                        arguments: [.title: "change the bottles", .timeExpression: "in 10 minutes"]
                    )
                )
            )
        ) {
            self.id = id
            self.state = availability
            self.result = result
        }

        func availability() async -> ActionModelAvailability { state }

        func generateSemanticAction(
            request: ActionModelRequest,
            constraints: ActionGenerationConstraints
        ) async throws -> LocalSemanticActionResult {
            callCount += 1
            categories.append(request.detectedCategory)
            constrained.append(constraints)
            return try result.get()
        }
    }

    private struct Harness {
        let engine: AssistantEngine
        let repositories: AssistantRepositories
        let chat: StubAIProvider
        let backend: ScriptedActionBackend
        let conversationID: Conversation.ID
    }

    private func makeHarness(
        chatKind: AIProviderKind = .development,
        backend: ScriptedActionBackend = ScriptedActionBackend(),
        withActionSystem: Bool = true
    ) async throws -> Harness {
        let dateProvider = FixedDateProvider(now: now, timeZone: athens)
        let repositories = AssistantRepositories.ephemeral()

        let chat = StubAIProvider(
            id: "test.chat", kind: chatKind, responses: [
                AIResponse(text: "Chat answered.", providerID: "test.chat"),
            ]
        )

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = chat.metadata.id
        try await repositories.settings.update(settings)

        let actions = MetisActionSystem(
            registry: ActionModelRegistry(backends: [backend]),
            resolver: LocalSemanticActionResolver(dateProvider: dateProvider)
        )

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [chat]),
            repositories: repositories,
            services: PlatformServices.mock(log: PlatformEventLog()),
            dateProvider: dateProvider,
            actions: withActionSystem ? actions : nil
        )
        let conversation = try await engine.startConversation(title: "Routing")

        return Harness(
            engine: engine,
            repositories: repositories,
            chat: chat,
            backend: backend,
            conversationID: conversation.id
        )
    }

    // MARK: Chat — section 27

    func testAnOrdinaryQuestionGoesToTheSelectedChatModel() async throws {
        let harness = try await makeHarness()

        let turn = try await harness.engine.send(
            "Why do people use reminders?", in: harness.conversationID
        )

        XCTAssertEqual(turn.assistantMessage.text, "Chat answered.")
        XCTAssertEqual(turn.providerID, harness.chat.metadata.id)
        XCTAssertEqual(harness.chat.receivedRequests.count, 1)
        let actionCalls = await harness.backend.callCount
        XCTAssertEqual(actionCalls, 0, "the action model must not run for a question")
    }

    // MARK: Action — sections 28 to 33

    func testAReminderRequestGoesToTheActionModelAndNotTheChatModel() async throws {
        let harness = try await makeHarness()

        let turn = try await harness.engine.send(
            "Remind me in 10 minutes to change bottles.", in: harness.conversationID
        )

        let actionCalls = await harness.backend.callCount
        XCTAssertEqual(actionCalls, 1)
        XCTAssertTrue(
            harness.chat.receivedRequests.isEmpty,
            "the selected chat model must not be asked to interpret an action"
        )
        XCTAssertEqual(turn.providerID, ActionTurnProvider.providerID)

        // And it went all the way through the existing pipeline: a real tool
        // ran and produced a real result.
        XCTAssertEqual(turn.results.count, 1)
        XCTAssertEqual(turn.results.first?.kind, .createReminder)
        XCTAssertTrue(turn.results.first?.outcome.didChangeAnything == true)
    }

    /// Section 28: the router's family reaches the action model as a hint.
    func testTheDetectedCategoryReachesTheActionModel() async throws {
        let harness = try await makeHarness()
        _ = try await harness.engine.send(
            "Remind me in 10 minutes to change bottles.", in: harness.conversationID
        )
        let categories = await harness.backend.categories
        XCTAssertEqual(categories, [.reminder])
    }

    func testAMemoryRequestReachesTheActionModel() async throws {
        let harness = try await makeHarness(
            backend: ScriptedActionBackend(
                result: .success(
                    .action(
                        LocalSemanticAction(
                            intent: .memoryStore,
                            arguments: [.content: "John's birthday is May 3"]
                        )
                    )
                )
            )
        )

        let turn = try await harness.engine.send(
            "Remember that John's birthday is May 3.", in: harness.conversationID
        )

        XCTAssertTrue(harness.chat.receivedRequests.isEmpty)
        XCTAssertEqual(turn.results.first?.kind, .storeMemory)
    }

    func testATaskRequestReachesTheActionModel() async throws {
        let harness = try await makeHarness(
            backend: ScriptedActionBackend(
                result: .success(
                    .action(
                        LocalSemanticAction(intent: .taskCreate, arguments: [.title: "Buy milk"])
                    )
                )
            )
        )

        let turn = try await harness.engine.send(
            "Create a task to buy milk.", in: harness.conversationID
        )

        XCTAssertTrue(harness.chat.receivedRequests.isEmpty)
        XCTAssertEqual(turn.results.first?.kind, .createTask)
        let tasks = try await harness.repositories.tasks.tasks(matching: .outstanding)
        XCTAssertEqual(tasks.first?.title, "Buy milk")
    }

    func testACalendarRequestReachesTheActionModel() async throws {
        let harness = try await makeHarness(
            backend: ScriptedActionBackend(
                result: .success(
                    .action(
                        LocalSemanticAction(
                            intent: .calendarCreate,
                            arguments: [.title: "Dentist", .timeExpression: "tomorrow at 3"]
                        )
                    )
                )
            )
        )

        let turn = try await harness.engine.send(
            "Add a dentist appointment tomorrow at 3.", in: harness.conversationID
        )

        XCTAssertTrue(harness.chat.receivedRequests.isEmpty)
        XCTAssertEqual(turn.results.first?.kind, .createCalendarEvent)
    }

    // MARK: The central claim — sections 12 and 37

    /// The whole point of the part, asserted directly: a chat-only selected
    /// model does not stop the phone being operated.
    ///
    /// The chat provider here is Apple's kind, offers no tools in its responses
    /// and is never invoked at all — and the reminder is still created.
    func testAChatOnlySelectedModelDoesNotBlockActions() async throws {
        let harness = try await makeHarness(chatKind: .appleFoundationModels)

        let turn = try await harness.engine.send(
            "Remind me in 10 minutes.", in: harness.conversationID
        )

        XCTAssertTrue(harness.chat.receivedRequests.isEmpty)
        XCTAssertEqual(turn.results.first?.kind, .createReminder)
        XCTAssertTrue(turn.results.first?.outcome.didChangeAnything == true)
    }

    /// Section 38: swapping the user's chat model changes nothing about the
    /// action path.
    func testChangingTheChatModelDoesNotChangeTheActionBackend() async throws {
        let harness = try await makeHarness()

        var settings = try await harness.repositories.settings.settings()
        settings.preferredProviderID = "some.other.provider"
        settings.routingPolicy = .preferMostCapable
        try await harness.repositories.settings.update(settings)

        let turn = try await harness.engine.send(
            "Remind me in 10 minutes.", in: harness.conversationID
        )

        let actionCalls = await harness.backend.callCount
        XCTAssertEqual(actionCalls, 1)
        XCTAssertEqual(turn.providerID, ActionTurnProvider.providerID)
    }

    // MARK: The hard requirement — sections 15, 16 and 36

    func testAnUnavailableActionBackendFailsSafely() async throws {
        let harness = try await makeHarness(
            backend: ScriptedActionBackend(
                availability: .unavailable(reason: "No action model is installed.")
            )
        )

        let turn = try await harness.engine.send(
            "Remind me in 10 minutes to change bottles.", in: harness.conversationID
        )

        // No fallback: the chat model was never asked.
        XCTAssertTrue(
            harness.chat.receivedRequests.isEmpty,
            "an action request must never be handed to the chat model"
        )
        // Nothing was interpreted and nothing ran.
        let actionCalls = await harness.backend.callCount
        XCTAssertEqual(actionCalls, 0)
        XCTAssertTrue(turn.results.isEmpty)
        XCTAssertTrue(turn.plan.actions.isEmpty)
        // And the user is told, concisely.
        XCTAssertEqual(turn.assistantMessage.text, MetisActionSystem.unavailableMessage)
        XCTAssertEqual(turn.status, .failed)
    }

    /// Section 20: the safe failure is still a turn in the conversation, in the
    /// same store, with the same message shape.
    func testTheSafeFailureIsRecordedInTheConversation() async throws {
        let harness = try await makeHarness(
            backend: ScriptedActionBackend(availability: .unavailable(reason: "No model."))
        )

        _ = try await harness.engine.send(
            "Remind me in 10 minutes.", in: harness.conversationID
        )

        let stored = try await harness.repositories.conversations.conversation(
            id: harness.conversationID
        )
        let messages = try XCTUnwrap(stored?.messages)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.text, MetisActionSystem.unavailableMessage)
    }

    // MARK: The dedicated action model — Part 3, sections 56 and 57

    /// Section 56. A question loads nothing and asks nothing of the action
    /// model — asserted on the counters rather than inferred from the reply.
    func testChatNeverTouchesTheActionModel() async throws {
        let harness = try await makeHarness()

        _ = try await harness.engine.send(
            "Explain why reminders are useful.", in: harness.conversationID
        )

        let actionCalls = await harness.backend.callCount
        XCTAssertEqual(actionCalls, 0, "no action-model inference for a question")
        XCTAssertEqual(harness.chat.receivedRequests.count, 1)
    }

    /// Section 57, and section 39. The action request never reaches the chat
    /// provider, even for interpretation.
    func testTheActionModelInterpretsAndTheChatModelIsNotConsulted() async throws {
        let harness = try await makeHarness()

        _ = try await harness.engine.send(
            "Remind me in 10 minutes.", in: harness.conversationID
        )

        let actionCalls = await harness.backend.callCount
        XCTAssertEqual(actionCalls, 1)
        XCTAssertTrue(harness.chat.receivedRequests.isEmpty)
    }

    /// Section 55, at the engine level: the two selections are independent
    /// settings, and changing the chat one leaves the action one alone.
    func testChangingTheChatModelLeavesTheActionSelectionAlone() async throws {
        let harness = try await makeHarness()

        var settings = try await harness.repositories.settings.settings()
        settings.actionModel.selectedModelID = "action-b"
        try await harness.repositories.settings.update(settings)

        settings = try await harness.repositories.settings.settings()
        settings.selectedLocalModelID = "chat-c"
        settings.preferredProviderID = "some.other.provider"
        try await harness.repositories.settings.update(settings)

        let after = try await harness.repositories.settings.settings()
        XCTAssertEqual(after.actionModel.selectedModelID, "action-b")
        XCTAssertEqual(after.selectedLocalModelID, "chat-c")
    }

    // MARK: Backwards compatibility

    /// A build with no action system behaves exactly as the app did before the
    /// fork existed: everything is chat. This is what keeps every existing
    /// composition and test working untouched.
    func testWithNoActionSystemEveryMessageIsChat() async throws {
        let harness = try await makeHarness(withActionSystem: false)

        let turn = try await harness.engine.send(
            "Remind me in 10 minutes to change bottles.", in: harness.conversationID
        )

        XCTAssertEqual(turn.providerID, harness.chat.metadata.id)
        XCTAssertEqual(harness.chat.receivedRequests.count, 1)
        let actionCalls = await harness.backend.callCount
        XCTAssertEqual(actionCalls, 0)
    }
}
