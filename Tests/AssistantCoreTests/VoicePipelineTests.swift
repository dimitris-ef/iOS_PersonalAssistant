import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import AssistantVoice
import MockPlatform
import XCTest
@testable import AssistantCore

/// The claim Part 5 is built on: **voice is an input method, not a second
/// assistant.**
///
/// `AssistantVoiceTests` proves a transcript reaches the submission closure.
/// This proves what happens *after* that closure — that a spoken sentence gets
/// the whole pipeline. Memory retrieval, provider routing, tool validation,
/// authorization, planning and platform execution all run, because the closure
/// the coordinator was given is the same function typed input calls.
///
/// It lives in `AssistantCoreTests` rather than the voice tests deliberately:
/// the voice module depends on nothing in this package, so it *cannot* import
/// the engine, and the only place this can be asserted is where both are
/// visible. That inability is the architecture working.
@MainActor
final class VoicePipelineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds the same wiring `AppModel` does, minus SwiftUI.
    private func makeStack(
        provider: any AIProvider
    ) async throws -> (VoiceCoordinator, MockSpeechInputService, AssistantRepositories, PlatformServices) {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = provider.metadata.id
        settings.routingPolicy = .explicit
        try await repositories.settings.update(settings)

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [provider]),
            repositories: repositories,
            services: services,
            dateProvider: FixedDateProvider(now: now)
        )
        let conversation = try await engine.startConversation()

        let input = MockSpeechInputService()
        let coordinator = VoiceCoordinator(
            input: input,
            output: nil,
            // The point of the whole test: this closure is the ordinary
            // submission path. Nothing voice-specific is threaded through it.
            submit: { text in
                _ = try? await engine.send(text, in: conversation.id)
            }
        )
        return (coordinator, input, repositories, services)
    }

    // MARK: The pipeline

    /// A spoken command must reach the platform layer the long way round —
    /// through the model, the validator and the authorizer — and never by the
    /// speech layer interpreting "7" itself.
    func testASpokenCommandRunsTheWholeToolPipeline() async throws {
        let alarmCall = try ToolCallFactory.make(
            .createAlarm,
            CreateAlarmInput(
                label: "Wake up",
                fireDate: now.addingTimeInterval(TimeSpan.hours(12))
            )
        )
        let provider = StubAIProvider(
            id: "test.voice",
            responses: [
                AIResponse(
                    text: "Alarm set.",
                    toolCalls: [alarmCall],
                    stopReason: .toolCalls,
                    providerID: "test.voice"
                )
            ]
        )
        let (coordinator, input, _, services) = try await makeStack(provider: provider)

        coordinator.startListening()
        try await settle()
        await input.emitFinal("Set an alarm tomorrow for 7.")
        try await settle()

        // The model was asked, with the spoken words as the user message.
        let request = try XCTUnwrap(provider.receivedRequests.last)
        XCTAssertEqual(
            request.messages.last(where: { $0.role == .user })?.content,
            "Set an alarm tomorrow for 7."
        )

        // And the alarm exists — which it can only do by having gone through
        // decoding, validation, authorization and the executor.
        let alarms = try await services.alarms.scheduledAlarms()
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms.first?.label, "Wake up")
    }

    /// Voice gets the same memory context typed input does. There is no
    /// separate retrieval path for spoken requests.
    func testASpokenRequestStillReceivesRelevantMemory() async throws {
        let provider = StubAIProvider(id: "test.voice", text: "About 30 minutes.")
        let (coordinator, input, repositories, _) = try await makeStack(provider: provider)

        try await repositories.memories.store(
            MemoryItem(
                kind: .routine,
                content: "Needs 30 minutes to get ready",
                createdAt: now,
                source: .user
            )
        )

        coordinator.startListening()
        try await settle()
        await input.emitFinal("How long do I need to get ready?")
        try await settle()

        let prompt = try XCTUnwrap(provider.lastSystemPrompt)
        XCTAssertTrue(
            prompt.contains("Needs 30 minutes to get ready"),
            "ContextAssembler and MemoryRetrievalService must run for spoken input too"
        )
    }

    /// Whatever the user says, the speech layer never touches a platform
    /// service. Cancelling proves the negative case as well: nothing happens
    /// at all.
    func testCancellingASpokenCommandTouchesNothing() async throws {
        let provider = StubAIProvider(id: "test.voice", text: "Should never be asked.")
        let (coordinator, input, repositories, services) = try await makeStack(provider: provider)

        coordinator.startListening()
        try await settle()
        await input.emitPartial("Set an alarm for 7")
        try await settle()

        coordinator.cancelListening()
        try await settle()

        XCTAssertEqual(provider.receivedRequests.count, 0, "The model was never asked")

        let alarms = try await services.alarms.scheduledAlarms()
        let notifications = try await services.notifications.pendingNotifications()
        XCTAssertTrue(alarms.isEmpty, "No alarm — the speech layer cannot reach AlarmKit")
        XCTAssertTrue(notifications.isEmpty)

        // And nothing was written down. A cancelled sentence was never said.
        let conversations = try await repositories.conversations.allConversations()
        let messages = conversations.flatMap(\.messages)
        XCTAssertTrue(
            messages.filter { $0.role == .user }.isEmpty,
            "A cancelled transcript must not become a stored message"
        )
    }

    // MARK: Provider independence

    /// The speech layer does not know or care which model is selected.
    func testVoiceWorksTheSameAgainstAnyProvider() async throws {
        for id: AIProviderIdentifier in ["test.remote", "test.apple", "test.scripted"] {
            let provider = StubAIProvider(id: id, text: "Noted.")
            let (coordinator, input, repositories, _) = try await makeStack(provider: provider)

            coordinator.startListening()
            try await settle()
            await input.emitFinal("Remember that I like mornings.")
            try await settle()

            XCTAssertEqual(
                provider.receivedRequests.count, 1,
                "\(id) should have been asked exactly once"
            )

            let conversations = try await repositories.conversations.allConversations()
            let spoken = conversations
                .flatMap(\.messages)
                .filter { $0.role == .user }
                .map(\.text)
            XCTAssertEqual(
                spoken, ["Remember that I like mornings."],
                "The stored message is ordinary text, whichever provider ran"
            )
        }
    }

    /// A spoken message is stored exactly like a typed one — no alternate
    /// format, no second repository, no marker that would make readers handle
    /// two kinds of message.
    func testASpokenMessageIsStoredLikeAnyOther() async throws {
        let provider = StubAIProvider(id: "test.voice", text: "Noted.")
        let (coordinator, input, repositories, _) = try await makeStack(provider: provider)

        coordinator.startListening()
        try await settle()
        await input.emitFinal("Book a haircut on Saturday.")
        try await settle()

        let stored = try await repositories.conversations.allConversations()
        let conversation = try XCTUnwrap(stored.first)
        let user = try XCTUnwrap(conversation.messages.first { $0.role == .user })
        XCTAssertEqual(user.text, "Book a haircut on Saturday.")
        XCTAssertEqual(user.role, .user)
    }

    // MARK: Helpers

    private func settle(iterations: Int = 12) async throws {
        for _ in 0..<iterations {
            await Task.yield()
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }
}
