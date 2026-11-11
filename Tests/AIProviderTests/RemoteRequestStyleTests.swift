import AssistantAI
import AssistantDomain
import XCTest
@testable import AIProviderRemote

/// Build 27 setup: the owner chose OpenAI's GPT-6 Luna. OpenAI's recent models
/// refuse `max_tokens` and a custom temperature, which the app always sent.
final class RemoteRequestStyleTests: XCTestCase {

    // MARK: The rule

    func testOpenAIStartsWithTheSettingsItsModelsAccept() {
        let style = RemoteRequestStyle.initial(forHost: "api.openai.com")
        XCTAssertEqual(style.tokenLimitField, .maxCompletionTokens)
        XCTAssertFalse(style.sendsTemperature)
        XCTAssertEqual(RemoteRequestStyle.initial(forHost: "openrouter.ai"), .classic)
    }

    func testARefusedSettingIsChangedByName() {
        let fromMaxTokens = RemoteRequestStyle.classic.adjusted(
            afterRejection: "Unsupported parameter: 'max_tokens' is not supported with this "
                + "model. Use 'max_completion_tokens' instead."
        )
        XCTAssertEqual(fromMaxTokens?.tokenLimitField, .maxCompletionTokens)
        XCTAssertEqual(fromMaxTokens?.sendsTemperature, true, "only the named setting changes")

        let fromTemperature = RemoteRequestStyle.classic.adjusted(
            afterRejection: "Unsupported value: 'temperature' does not support 0.3 with this model."
        )
        XCTAssertEqual(fromTemperature?.sendsTemperature, false)

        let fromCompletionTokens = RemoteRequestStyle.openAI.adjusted(
            afterRejection: "Unrecognized request argument supplied: max_completion_tokens"
        )
        XCTAssertEqual(fromCompletionTokens?.tokenLimitField, .maxTokens)

        let needsEffort = RemoteRequestStyle.openAI.adjusted(
            afterRejection: "Function tools require reasoning_effort to be 'none'."
        )
        XCTAssertEqual(needsEffort?.reasoningEffort, "none")
    }

    func testAnErrorThatNamesNoSettingIsNotRetried() {
        XCTAssertNil(RemoteRequestStyle.classic.adjusted(afterRejection: "The model does not exist."))
        XCTAssertNil(RemoteRequestStyle.classic.adjusted(afterRejection: nil))
    }

    // MARK: Through the provider

    func testTheProviderRetriesOnceWithTheNamedSettingChanged() async throws {
        let transport = SequencedTransport(responses: [
            HTTPResponse(
                statusCode: 400,
                body: Data(#"""
                {"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.","type":"invalid_request_error"}}
                """#.utf8)
            ),
            HTTPResponse(
                statusCode: 200,
                body: Data(#"""
                {"choices":[{"message":{"role":"assistant","content":"Hello."},"finish_reason":"stop"}]}
                """#.utf8)
            ),
        ])
        let provider = RemoteAIProvider(
            adapter: OpenAICompatibleAdapter(),
            configuration: StaticRemoteAIConfigurationSource(
                RemoteAIConfiguration(baseURL: "https://router.example.com/v1", model: "gpt-6-luna")
            ),
            credentials: FixedCredentials(),
            transport: transport
        )

        let response = try await provider.respond(
            to: AIRequest(
                systemPrompt: "Brief.",
                messages: [AIMessage(role: .user, content: "Hi")],
                options: AIGenerationOptions(maximumOutputTokens: 300)
            )
        )

        XCTAssertEqual(response.text, "Hello.")
        let sent = transport.sentBodies
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotNil(sent[0]["max_tokens"])
        XCTAssertNil(sent[1]["max_tokens"])
        XCTAssertNotNil(sent[1]["max_completion_tokens"])
    }

    func testOpenAIIsAskedWithoutMaxTokensOrTemperature() async throws {
        let transport = SequencedTransport(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"""
                {"choices":[{"message":{"role":"assistant","content":"Hello."},"finish_reason":"stop"}]}
                """#.utf8)
            ),
        ])
        let provider = RemoteAIProvider(
            adapter: OpenAICompatibleAdapter(),
            configuration: StaticRemoteAIConfigurationSource(
                RemoteAIConfiguration(baseURL: "api.openai.com", model: "gpt-6-luna")
            ),
            credentials: FixedCredentials(),
            transport: transport
        )

        _ = try await provider.respond(
            to: AIRequest(
                systemPrompt: "Brief.",
                messages: [AIMessage(role: .user, content: "Hi")],
                options: AIGenerationOptions(temperature: 0.3, maximumOutputTokens: 300)
            )
        )

        let body = try XCTUnwrap(transport.sentBodies.first)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["temperature"])
        XCTAssertNotNil(body["max_completion_tokens"])
        XCTAssertEqual(transport.sentBodies.count, 1, "right the first time")
    }
}

// MARK: - Stubs

/// Replays responses in order and records the JSON bodies it was sent.
private final class SequencedTransport: HTTPTransport, @unchecked Sendable {
    private let responses: [HTTPResponse]
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    var sentBodies: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        let object = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        bodies.append(object as? [String: Any] ?? [:])
        return responses[min(bodies.count - 1, responses.count - 1)]
    }
}

private struct FixedCredentials: CredentialProvider {
    func credential(for providerID: AIProviderIdentifier) async -> String? { "test-key" }
}
