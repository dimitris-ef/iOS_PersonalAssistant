import AssistantAI
import AssistantDomain
import AssistantTools
import XCTest
@testable import AIProviderRemote

/// Everything here runs against a stub transport. No test in this file — or
/// anywhere in the suite — touches a network or needs an API key, which is what
/// keeps CI credential-free.
final class RemoteAIProviderTests: XCTestCase {

    // MARK: Fixtures

    private let readyConfiguration = RemoteAIConfiguration(
        baseURL: "https://api.example.com/v1",
        model: "some-provider-model"
    )

    private func makeProvider(
        configuration: RemoteAIConfiguration? = nil,
        credential: String? = "test-key",
        transport: StubTransport
    ) -> RemoteAIProvider {
        RemoteAIProvider(
            adapter: OpenAICompatibleAdapter(),
            configuration: StaticRemoteAIConfigurationSource(configuration ?? readyConfiguration),
            credentials: StubCredentials(value: credential),
            transport: transport
        )
    }

    private func makeRequest(tools: [AIToolSchema] = []) -> AIRequest {
        AIRequest(
            systemPrompt: "You are a personal assistant.",
            messages: [AIMessage(role: .user, content: "Hello")],
            tools: tools
        )
    }

    private func reminderToolSchema() -> AIToolSchema {
        AIToolSchema(
            name: ToolKind.createReminder.rawValue,
            description: "Add an entry to the reminders list.",
            parameters: .object(
                properties: [
                    "title": .string(description: "What to remember"),
                    "dueDate": .string(format: .dateTime),
                    "importance": .enumeration(values: ["low", "normal", "high"]),
                ],
                required: ["title"]
            )
        )
    }

    // MARK: Request generation

    func testBuildsTheChatCompletionsRequest() async throws {
        let transport = StubTransport(response: .success(Fixtures.textResponse))
        let provider = makeProvider(transport: transport)

        _ = try await provider.respond(to: makeRequest())

        let sent = try XCTUnwrap(transport.sentRequests.last)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(
            sent.url.absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(sent.timeout, 60)

        let body = try XCTUnwrap(sent.body)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "some-provider-model")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        // The system prompt comes from the engine's prompt builder; the adapter
        // adds nothing of its own.
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "You are a personal assistant.")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "Hello")
    }

    func testSendsTheBearerTokenWithoutItAppearingElsewhere() async throws {
        let transport = StubTransport(response: .success(Fixtures.textResponse))
        let provider = makeProvider(credential: "secret-token", transport: transport)

        _ = try await provider.respond(to: makeRequest())

        let sent = try XCTUnwrap(transport.sentRequests.last)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer secret-token")

        // The redacted view is what any logging uses.
        XCTAssertEqual(sent.redactedHeaders["Authorization"], "<redacted>")

        // The key must not have leaked into the body.
        let body = String(data: try XCTUnwrap(sent.body), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("secret-token"))
    }

    func testSendsTheApplicationsExistingToolSchemas() async throws {
        let transport = StubTransport(response: .success(Fixtures.textResponse))
        let provider = makeProvider(transport: transport)

        _ = try await provider.respond(to: makeRequest(tools: [reminderToolSchema()]))

        let body = try XCTUnwrap(transport.sentRequests.last?.body)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(json["tool_choice"] as? String, "auto")

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")

        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "createReminder")

        // The schema is the app's own, converted — not a second definition.
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(parameters["required"] as? [String], ["title"])

        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let dueDate = try XCTUnwrap(properties["dueDate"] as? [String: Any])
        XCTAssertEqual(dueDate["format"] as? String, "date-time")
        let importance = try XCTUnwrap(properties["importance"] as? [String: Any])
        XCTAssertEqual(importance["enum"] as? [String], ["low", "normal", "high"])
    }

    func testOmitsToolsWhenTheAppOffersNone() async throws {
        let transport = StubTransport(response: .success(Fixtures.textResponse))
        let provider = makeProvider(transport: transport)

        _ = try await provider.respond(to: makeRequest())

        let body = try XCTUnwrap(transport.sentRequests.last?.body)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["tool_choice"])
    }

    // MARK: Normal responses

    func testParsesAPlainTextReply() async throws {
        let transport = StubTransport(response: .success(Fixtures.textResponse))
        let provider = makeProvider(transport: transport)

        let response = try await provider.respond(to: makeRequest())

        XCTAssertEqual(response.text, "Sure. I can help with that.")
        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.stopReason, .endTurn)
        XCTAssertEqual(response.usage.inputTokens, 12)
        XCTAssertEqual(response.usage.outputTokens, 7)
        XCTAssertEqual(response.providerID, "remote.openai-compatible")
    }

    // MARK: Tool calls

    func testParsesASingleToolCall() async throws {
        let transport = StubTransport(response: .success(Fixtures.singleToolCallResponse))
        let provider = makeProvider(transport: transport)

        let response = try await provider.respond(to: makeRequest(tools: [reminderToolSchema()]))

        XCTAssertEqual(response.stopReason, .toolCalls)
        XCTAssertEqual(response.toolCalls.count, 1)

        let call = try XCTUnwrap(response.toolCalls.first)
        XCTAssertEqual(call.name, "createReminder")
        XCTAssertEqual(call.arguments["title"]?.stringValue, "Call the dentist")

        // The arguments arrive as the app's neutral JSON type, ready for
        // ToolRequestDecoder — no wire type escapes the adapter.
        XCTAssertNotNil(call.arguments.objectValue)
    }

    func testParsesMultipleToolCalls() async throws {
        let transport = StubTransport(response: .success(Fixtures.multipleToolCallsResponse))
        let provider = makeProvider(transport: transport)

        let response = try await provider.respond(to: makeRequest(tools: [reminderToolSchema()]))

        XCTAssertEqual(response.toolCalls.map(\.name), ["createReminder", "createTask"])
        XCTAssertEqual(
            response.toolCalls.last?.arguments["title"]?.stringValue,
            "Book train tickets"
        )
    }

    func testKeepsAnUnknownToolSoThePipelineCanRejectIt() async throws {
        let transport = StubTransport(response: .success(Fixtures.unknownToolResponse))
        let provider = makeProvider(transport: transport)

        let response = try await provider.respond(to: makeRequest())

        // The adapter deserialises; it does not decide what is legitimate. The
        // name is passed through so `ToolRequestDecoder` rejects it by name and
        // the rejection is visible, rather than the call vanishing here.
        XCTAssertEqual(response.toolCalls.map(\.name), ["deleteAllUserData"])

        // Proof that nothing could execute it: the decoder refuses.
        let decoder = ToolRequestDecoder()
        let outcome = decoder.decode(
            response.toolCalls.map {
                AIToolCallEnvelope(id: $0.id, name: $0.name, arguments: $0.arguments)
            }
        )
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.rejected.first?.error, .unknownTool(name: "deleteAllUserData"))
    }

    func testMalformedToolArgumentsBecomeARejectableCall() async throws {
        let transport = StubTransport(response: .success(Fixtures.malformedArgumentsResponse))
        let provider = makeProvider(transport: transport)

        let response = try await provider.respond(to: makeRequest())

        // Null arguments rather than a silent drop, so the decoder rejects it
        // and the user sees that the model asked for something unusable.
        let call = try XCTUnwrap(response.toolCalls.first)
        XCTAssertEqual(call.arguments, .null)

        let outcome = ToolRequestDecoder().decode(
            [AIToolCallEnvelope(id: call.id, name: call.name, arguments: call.arguments)]
        )
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.rejected.count, 1)
    }

    func testReplaysToolResultsOnAFollowUpRequest() async throws {
        let transport = StubTransport(response: .success(Fixtures.textResponse))
        let provider = makeProvider(transport: transport)

        let callID = ToolCallID()
        let request = AIRequest(
            systemPrompt: "sys",
            messages: [
                AIMessage(role: .user, content: "Remind me to call the dentist"),
                AIMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AIToolCall(
                            id: callID,
                            name: "createReminder",
                            arguments: .object(["title": .string("Call the dentist")])
                        )
                    ]
                ),
                AIMessage(role: .tool, content: "Done.", toolCallID: callID),
            ]
        )

        _ = try await provider.respond(to: request)

        let body = try XCTUnwrap(transport.sentRequests.last?.body)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)

        let tool = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" })
        // The ids must match between the two, or the service rejects the turn.
        XCTAssertEqual(tool["tool_call_id"] as? String, toolCalls[0]["id"] as? String)
        XCTAssertEqual(tool["content"] as? String, "Done.")
    }

    // MARK: Configuration

    func testRefusesToCallOutWithoutCredentials() async throws {
        let transport = StubTransport(response: .success(Fixtures.textResponse))
        let provider = makeProvider(credential: nil, transport: transport)

        do {
            _ = try await provider.respond(to: makeRequest())
            XCTFail("Expected a missing-credential failure")
        } catch let error as AIProviderError {
            guard case .missingCredentials(let detail) = error else {
                return XCTFail("Expected .missingCredentials, got \(error)")
            }
            XCTAssertTrue(detail.contains("API key"))
        }

        // The important assertion: nothing was sent.
        XCTAssertTrue(transport.sentRequests.isEmpty)
    }

    func testAvailabilityReportsWhatIsMissing() async {
        let transport = StubTransport(response: .success(Fixtures.textResponse))

        let unconfigured = makeProvider(
            configuration: RemoteAIConfiguration(),
            credential: nil,
            transport: transport
        )
        let availability = await unconfigured.availability()
        guard case .configurationRequired(let reason) = availability else {
            return XCTFail("Expected .configurationRequired, got \(availability)")
        }
        XCTAssertTrue(reason.contains("endpoint"))
        XCTAssertTrue(availability.isUserResolvable)

        let ready = makeProvider(transport: transport)
        let readyAvailability = await ready.availability()
        XCTAssertTrue(readyAvailability.isAvailable)
    }

    func testDeclaresItCanContinueAfterToolResults() {
        let transport = StubTransport(response: .success(Fixtures.textResponse))
        let provider = makeProvider(transport: transport)

        XCTAssertTrue(provider.metadata.supportsToolResultContinuation)
        XCTAssertEqual(provider.metadata.kind, .remoteAPI)
    }

    // MARK: HTTP errors

    func testMapsHTTPStatusesToUsefulErrors() async throws {
        let cases: [(Int, String)] = [
            (400, "rejected the request"),
            (401, "rejected the API key"),
            (403, "rejected the API key"),
            (404, "check the endpoint and model"),
            (429, "Rate limited"),
            (500, "had a problem"),
            (503, "had a problem"),
        ]

        for (status, expectedFragment) in cases {
            let transport = StubTransport(
                response: .success(
                    HTTPResponse(
                        statusCode: status,
                        body: Data(#"{"error":{"message":"upstream detail","type":"x"}}"#.utf8)
                    )
                )
            )
            let provider = makeProvider(transport: transport)

            do {
                _ = try await provider.respond(to: makeRequest())
                XCTFail("Expected HTTP \(status) to fail")
            } catch let error as AIProviderError {
                guard case .invalidResponse(let detail) = error else {
                    return XCTFail("Expected .invalidResponse for \(status), got \(error)")
                }
                XCTAssertTrue(
                    detail.contains(expectedFragment),
                    "HTTP \(status) produced \"\(detail)\", expected it to mention \"\(expectedFragment)\""
                )
                XCTAssertTrue(detail.contains("upstream detail"))
            }
        }
    }

    func testReadsRetryAfterOnRateLimits() {
        let error = RemoteAIError.from(
            status: 429,
            apiError: .init(message: "slow down", type: nil, code: nil),
            retryAfter: 30
        )
        XCTAssertEqual(error, .rateLimited(detail: "slow down", retryAfter: 30))
        XCTAssertTrue(error.userFacingDescription.contains("30s"))
    }

    func testRecognisesAnUnsupportedToolCapability() {
        let error = RemoteAIError.from(
            status: 400,
            apiError: .init(
                message: "This model does not support tools",
                type: "invalid_request_error",
                code: nil
            )
        )
        guard case .toolCallingUnsupported = error else {
            return XCTFail("Expected .toolCallingUnsupported, got \(error)")
        }
    }

    func testFallsBackWhenTheErrorBodyIsNotTheExpectedShape() async throws {
        let transport = StubTransport(
            response: .success(
                HTTPResponse(statusCode: 502, body: Data("<html>Bad Gateway</html>".utf8))
            )
        )
        let provider = makeProvider(transport: transport)

        do {
            _ = try await provider.respond(to: makeRequest())
            XCTFail("Expected the 502 to fail")
        } catch let error as AIProviderError {
            // Parsing the body must never itself throw — the status still gets
            // through.
            guard case .invalidResponse(let detail) = error else {
                return XCTFail("Expected .invalidResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("502"))
        }
    }

    // MARK: Malformed successes

    func testRejectsResponsesItCannotUse() async throws {
        let bodies: [(String, String)] = [
            ("not json at all", "not valid JSON"),
            (#"{"choices":[]}"#, "no choices"),
            (#"{"choices":[{"index":0}]}"#, "no message"),
            (#"{"choices":[{"message":{"role":"assistant","content":null}}]}"#, "no text and no actions"),
        ]

        for (body, expectedFragment) in bodies {
            let transport = StubTransport(
                response: .success(HTTPResponse(statusCode: 200, body: Data(body.utf8)))
            )
            let provider = makeProvider(transport: transport)

            do {
                _ = try await provider.respond(to: makeRequest())
                XCTFail("Expected \"\(body)\" to be rejected")
            } catch let error as AIProviderError {
                guard case .invalidResponse(let detail) = error else {
                    return XCTFail("Expected .invalidResponse, got \(error)")
                }
                XCTAssertTrue(
                    detail.contains(expectedFragment),
                    "\"\(body)\" produced \"\(detail)\""
                )
            }
        }
    }

    // MARK: Transport failures

    func testMapsNetworkFailures() async throws {
        let cases: [(Int, String)] = [
            (NSURLErrorNotConnectedToInternet, "no internet"),
            (NSURLErrorTimedOut, "too long"),
            (NSURLErrorCannotFindHost, "host could not be found"),
            (NSURLErrorSecureConnectionFailed, "secure connection"),
        ]

        for (code, expectedFragment) in cases {
            let transport = StubTransport(
                response: .failure(NSError(domain: NSURLErrorDomain, code: code))
            )
            let provider = makeProvider(transport: transport)

            do {
                _ = try await provider.respond(to: makeRequest())
                XCTFail("Expected URL error \(code) to fail")
            } catch let error as AIProviderError {
                guard case .transport(let detail) = error else {
                    return XCTFail("Expected .transport for \(code), got \(error)")
                }
                XCTAssertTrue(
                    detail.lowercased().contains(expectedFragment),
                    "URL error \(code) produced \"\(detail)\""
                )
            }
        }
    }

    func testNoErrorDescriptionEverContainsTheCredential() {
        // A blunt guard against a credential reaching a log or an alert.
        let errors: [RemoteAIError] = [
            .notConfigured(missing: [.apiKey]),
            .invalidEndpoint("https://api.example.com"),
            .authenticationFailed(detail: "invalid api key"),
            .notFound(detail: nil),
            .rateLimited(detail: nil, retryAfter: 1),
            .requestRejected(status: 400, detail: "bad"),
            .serverError(status: 500, detail: nil),
            .toolCallingUnsupported(detail: nil),
            .network(detail: "offline"),
            .timedOut,
            .cancelled,
            .malformedResponse(detail: "nope"),
        ]

        for error in errors {
            XCTAssertFalse(error.userFacingDescription.contains("test-key"))
            XCTAssertFalse(error.category.isEmpty)
        }
    }
}

// MARK: - Fixtures

private enum Fixtures {
    static let textResponse = HTTPResponse(
        statusCode: 200,
        body: Data(#"""
        {
          "id": "chatcmpl-1",
          "model": "some-provider-model",
          "choices": [
            {
              "index": 0,
              "message": { "role": "assistant", "content": "Sure. I can help with that." },
              "finish_reason": "stop"
            }
          ],
          "usage": { "prompt_tokens": 12, "completion_tokens": 7 }
        }
        """#.utf8)
    )

    static let singleToolCallResponse = HTTPResponse(
        statusCode: 200,
        body: Data(#"""
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "createReminder",
                      "arguments": "{\"title\":\"Call the dentist\"}"
                    }
                  }
                ]
              },
              "finish_reason": "tool_calls"
            }
          ]
        }
        """#.utf8)
    )

    static let multipleToolCallsResponse = HTTPResponse(
        statusCode: 200,
        body: Data(#"""
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "I'll set both up.",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "function": {
                      "name": "createReminder",
                      "arguments": "{\"title\":\"Call the dentist\"}"
                    }
                  },
                  {
                    "id": "call_2",
                    "function": {
                      "name": "createTask",
                      "arguments": "{\"title\":\"Book train tickets\"}"
                    }
                  }
                ]
              },
              "finish_reason": "tool_calls"
            }
          ]
        }
        """#.utf8)
    )

    static let unknownToolResponse = HTTPResponse(
        statusCode: 200,
        body: Data(#"""
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {
                    "id": "call_1",
                    "function": { "name": "deleteAllUserData", "arguments": "{}" }
                  }
                ]
              },
              "finish_reason": "tool_calls"
            }
          ]
        }
        """#.utf8)
    )

    static let malformedArgumentsResponse = HTTPResponse(
        statusCode: 200,
        body: Data(#"""
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {
                    "id": "call_1",
                    "function": { "name": "createReminder", "arguments": "{not valid json" }
                  }
                ]
              },
              "finish_reason": "tool_calls"
            }
          ]
        }
        """#.utf8)
    )
}

// MARK: - Stubs

/// Records what was sent and replays a canned result. No sockets involved.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Outcome {
        case success(HTTPResponse)
        case failure(any Error)
    }

    private let outcome: Outcome
    private let lock = NSLock()
    private var requests: [HTTPRequest] = []

    init(response: Outcome) {
        self.outcome = response
    }

    var sentRequests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        requests.append(request)
        lock.unlock()

        switch outcome {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

private struct StubCredentials: CredentialProvider {
    let value: String?

    func credential(for providerID: AIProviderIdentifier) async -> String? { value }
}
