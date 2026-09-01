import AssistantDomain
import Foundation
import XCTest

@testable import AssistantAI

/// The dedicated action-model boundary: what it produces, what it refuses, and
/// what it never does on its own.
final class ActionModelBoundaryTests: XCTestCase {

    /// 31 August 2026, 14:20, Europe/Athens.
    private static let now = Date(timeIntervalSince1970: 1_788_175_200)
    private static let athens = TimeZone(identifier: "Europe/Athens")!

    private var clock: FixedDateProvider {
        FixedDateProvider(now: Self.now, timeZone: Self.athens)
    }

    // MARK: Doubles

    /// Records what it was asked, so a test can assert what the action model
    /// was — and was not — shown.
    private actor RecordingBackend: ActionModelProvider {
        nonisolated let id: String
        private let result: Result<LocalSemanticActionResult, ActionModelError>
        private let state: ActionModelAvailability
        private(set) var requests: [ActionModelRequest] = []

        init(
            id: String = "test.backend",
            availability: ActionModelAvailability = .available,
            result: Result<LocalSemanticActionResult, ActionModelError> = .success(
                .noActionNeeded(message: "")
            )
        ) {
            self.id = id
            self.state = availability
            self.result = result
        }

        func availability() async -> ActionModelAvailability { state }

        func generateSemanticAction(
            request: ActionModelRequest
        ) async throws -> LocalSemanticActionResult {
            requests.append(request)
            return try result.get()
        }
    }

    private struct RecordingSink: ActionSystemDiagnosticSink {
        let box: Box

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [ActionSystemDiagnosticEvent] = []

            func append(_ event: ActionSystemDiagnosticEvent) {
                lock.lock()
                defer { lock.unlock() }
                storage.append(event)
            }

            var events: [ActionSystemDiagnosticEvent] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        func record(_ event: ActionSystemDiagnosticEvent) { box.append(event) }
    }

    private func request(_ text: String) -> AIRequest {
        AIRequest(
            systemPrompt: "You are a personal assistant.",
            messages: [AIMessage(role: .user, content: text)],
            tools: []
        )
    }

    // MARK: The registry — section 14

    func testTheRegistryPicksTheFirstAvailableBackend() async {
        let unavailable = RecordingBackend(
            id: "a", availability: .unavailable(reason: "No model downloaded.")
        )
        let available = RecordingBackend(id: "b")
        let registry = ActionModelRegistry(backends: [unavailable, available])

        guard case .selected(let chosen) = await registry.selectBackend() else {
            return XCTFail("expected the second backend")
        }
        XCTAssertEqual(chosen.id, "b")
        XCTAssertTrue(await registry.availability().isAvailable)
    }

    /// Section 15: unavailable carries a reason, because "unavailable" alone is
    /// something neither the user nor a bug report can act on.
    func testAnUnavailableRegistryReportsWhy() async {
        let registry = ActionModelRegistry(backends: [
            RecordingBackend(availability: .unavailable(reason: "No model downloaded.")),
        ])
        guard case .unavailable(let reason) = await registry.selectBackend() else {
            return XCTFail("expected unavailable")
        }
        XCTAssertEqual(reason, "No model downloaded.")
    }

    func testAnEmptyRegistryIsUnavailableRatherThanCrashing() async {
        let registry = ActionModelRegistry()
        XCTAssertFalse(await registry.availability().isAvailable)
        XCTAssertNotNil(await registry.availability().reason)
    }

    /// Section 38: the action backend is not the chat provider registry, and
    /// changing one cannot change the other. They share no storage at all.
    func testTheActionRegistryIsIndependentOfTheProviderRegistry() async {
        let actions = ActionModelRegistry(backends: [RecordingBackend(id: "action")])
        let chat = AIProviderRegistry()
        await chat.register(
            ActionTurnProvider(
                backend: RecordingBackend(id: "unused"),
                resolver: LocalSemanticActionResolver(dateProvider: clock),
                dateProvider: clock
            )
        )
        await chat.unregister(ActionTurnProvider.providerID)

        // The chat registry is now empty; the action registry is untouched.
        XCTAssertTrue(await chat.allProviders().isEmpty)
        XCTAssertEqual(await actions.allBackends().count, 1)
        XCTAssertTrue(await actions.availability().isAvailable)
    }

    // MARK: What the action model is shown — sections 8 and 21

    func testTheActionModelSeesTheSentenceAndTheProtocolAndNothingElse() async throws {
        let backend = RecordingBackend(
            result: .success(
                .action(
                    LocalSemanticAction(
                        intent: .reminderCreate,
                        arguments: [.title: "change the bottles", .timeExpression: "in 10 minutes"]
                    )
                )
            )
        )
        let provider = ActionTurnProvider(
            backend: backend,
            resolver: LocalSemanticActionResolver(dateProvider: clock),
            dateProvider: clock,
            category: .reminder
        )

        _ = try await provider.respond(to: request("Remind me in 10 minutes to change bottles."))

        let requests = await backend.requests
        XCTAssertEqual(requests.count, 1)
        let seen = try XCTUnwrap(requests.first)
        XCTAssertEqual(seen.userRequest, "Remind me in 10 minutes to change bottles.")
        XCTAssertEqual(seen.now, Self.now)
        XCTAssertEqual(seen.timeZoneIdentifier, "Europe/Athens")
        XCTAssertEqual(seen.detectedCategory, .reminder)
        // The protocol, and only the intents that do something.
        XCTAssertFalse(seen.allowedIntents.contains(.chat))
        XCTAssertTrue(seen.allowedIntents.contains(.reminderCreate))
        // And structurally: there is no field on the request for a system
        // prompt, a history, a memory or a tool schema.
        XCTAssertEqual(
            Set(Mirror(reflecting: seen).children.compactMap(\.label)),
            ["userRequest", "now", "timeZoneIdentifier", "detectedCategory", "allowedIntents"]
        )
    }

    // MARK: The action turn — sections 9, 16 and 17

    func testAResolvedActionBecomesAToolCallForTheExistingPipeline() async throws {
        let backend = RecordingBackend(
            result: .success(
                .action(
                    LocalSemanticAction(
                        intent: .reminderCreate,
                        arguments: [.title: "change the bottles", .timeExpression: "in 10 minutes"]
                    )
                )
            )
        )
        let provider = ActionTurnProvider(
            backend: backend,
            resolver: LocalSemanticActionResolver(dateProvider: clock),
            dateProvider: clock,
            category: .reminder
        )

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "createReminder")
        XCTAssertEqual(response.stopReason, .toolCalls)
        // Section 47 of the semantic protocol, still true here: no sentence
        // claiming the thing happened before anything ran.
        XCTAssertTrue(response.text.isEmpty)
    }

    /// Section 17: the action turn does not resolve identifiers itself, and a
    /// target it cannot find becomes a question rather than an invented id.
    func testAnUnresolvableTargetAsksRatherThanActs() async throws {
        let backend = RecordingBackend(
            result: .success(
                .action(
                    LocalSemanticAction(
                        intent: .taskComplete, arguments: [.targetDescription: "the shopping"]
                    )
                )
            )
        )
        let provider = ActionTurnProvider(
            backend: backend,
            resolver: LocalSemanticActionResolver(dateProvider: clock, resources: nil),
            dateProvider: clock,
            category: .task
        )

        let response = try await provider.respond(to: request("Mark the shopping as done."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertFalse(response.text.isEmpty)
    }

    /// Section 26: a failing backend produces one concise sentence — no parser
    /// error, no protocol JSON, no backend name.
    func testAFailingBackendProducesASafeSentence() async throws {
        let backend = RecordingBackend(
            result: .failure(.semanticParsingFailed("missingRequiredField"))
        )
        let sink = RecordingSink(box: RecordingSink.Box())
        let provider = ActionTurnProvider(
            backend: backend,
            resolver: LocalSemanticActionResolver(dateProvider: clock),
            dateProvider: clock,
            category: .reminder,
            diagnostics: sink
        )

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, ActionTurnProvider.failureMessage)
        for forbidden in ["missingRequiredField", "intent", "json", "test.backend"] {
            XCTAssertFalse(
                response.text.lowercased().contains(forbidden.lowercased()),
                "the reply leaked \(forbidden)"
            )
        }
        // Section 25: it *is* recorded, as a structured category.
        XCTAssertTrue(
            sink.box.events.contains {
                if case .actionBackendFailure(_, let reason) = $0 {
                    return reason == "semanticParsingFailed"
                }
                return false
            }
        )
    }

    /// Section 16 at this layer: a backend with nothing to do answers for
    /// itself. It does not hand the request onward to be answered as though
    /// something had happened.
    func testNoActionNeededStaysInsideTheActionSystem() async throws {
        let backend = RecordingBackend(result: .success(.noActionNeeded(message: "")))
        let provider = ActionTurnProvider(
            backend: backend,
            resolver: LocalSemanticActionResolver(dateProvider: clock),
            dateProvider: clock
        )

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertFalse(response.text.isEmpty)
    }

    // MARK: Availability and metadata

    func testTheTurnProviderReportsItsBackendsAvailability() async {
        let provider = ActionTurnProvider(
            backend: RecordingBackend(availability: .unavailable(reason: "No model.")),
            resolver: LocalSemanticActionResolver(dateProvider: clock),
            dateProvider: clock
        )
        let availability = await provider.availability()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.reason, "No model.")
    }

    /// It is not a chat model, offers no models to pick from, and is not asked
    /// to write the confirmation sentence — `TurnSummarizer` does that from the
    /// real results.
    func testTheTurnProviderIsNotAConversationalist() async throws {
        let provider = ActionTurnProvider(
            backend: RecordingBackend(),
            resolver: LocalSemanticActionResolver(dateProvider: clock),
            dateProvider: clock
        )
        XCTAssertEqual(provider.metadata.kind, .actionModel)
        XCTAssertFalse(provider.metadata.supportsToolResultContinuation)
        XCTAssertFalse(provider.metadata.requiresCredentials)
        XCTAssertFalse(provider.metadata.requiresNetwork)
        XCTAssertTrue(try await provider.availableModels().isEmpty)
    }

    // MARK: Diagnostics — sections 22 to 25 and 41

    func testDiagnosticsCarryNoUserText() async throws {
        let secret = "zebra-flagstone-marmalade"
        let sink = RecordingSink(box: RecordingSink.Box())
        let provider = ActionTurnProvider(
            backend: RecordingBackend(result: .failure(.generationFailed("boom"))),
            resolver: LocalSemanticActionResolver(dateProvider: clock),
            dateProvider: clock,
            category: .reminder,
            diagnostics: sink
        )

        _ = try await provider.respond(to: request("Remind me in 10 minutes about \(secret)."))

        XCTAssertFalse(sink.box.events.isEmpty)
        for event in sink.box.events {
            XCTAssertFalse(
                String(describing: event).contains(secret),
                "\(event.name) carried the user's message"
            )
        }
        // And the start of processing was recorded (section 24).
        XCTAssertTrue(
            sink.box.events.contains {
                if case .semanticProcessingStarted(_, let category) = $0 {
                    return category == "reminder"
                }
                return false
            }
        )
    }
}
