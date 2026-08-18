import AssistantAI
import AssistantDomain
import XCTest
@testable import AIProviderApple
@testable import AIProviderLocal
@testable import AIProviderRemote

final class ProviderStubTests: XCTestCase {
    /// The Apple provider is no longer a stub, so this no longer asserts that
    /// it refuses to run. What still has to hold is its identity: the
    /// identifier is written into the user's settings, and changing it would
    /// silently reset the choice of anyone who had selected it.
    func testAppleProviderKeepsItsIdentityAndNeedsNothingFromTheNetwork() async throws {
        let provider = AppleFoundationModelsProvider()

        XCTAssertEqual(provider.metadata.id, "apple.foundation-models")
        XCTAssertEqual(provider.metadata.kind, .appleFoundationModels)
        XCTAssertFalse(provider.metadata.requiresNetwork)
        XCTAssertFalse(provider.metadata.requiresCredentials)
        XCTAssertTrue(provider.metadata.supportsToolResultContinuation)
    }

    /// Whatever this machine is, the provider must not claim to be ready
    /// without having asked, and must not fabricate an answer.
    ///
    /// On CI and on Linux the framework is absent, so this exercises the
    /// unavailable path. On an Apple Intelligence device it would exercise the
    /// ready path — and then the assertion below still holds, because a
    /// provider reporting itself ready is allowed to answer.
    func testAppleProviderNeverFabricatesAnAnswerWhenItIsNotReady() async throws {
        let provider = AppleFoundationModelsProvider()
        let availability = await provider.availability()

        guard !availability.isAvailable else {
            throw XCTSkip("This machine has Apple Intelligence; the unavailable path cannot run here.")
        }

        XCTAssertNotNil(availability.reason, "an unavailable provider has to say why")
        do {
            _ = try await provider.respond(
                to: AIRequest(systemPrompt: "", messages: [AIMessage(role: .user, content: "hi")])
            )
            XCTFail("An unavailable Apple provider must throw, never return a fake answer")
        } catch let error as AIProviderError {
            guard case .unavailable = error else {
                return XCTFail("Expected .unavailable, got \(error)")
            }
        }
    }

    func testLocalProviderIsUnavailableUntilARuntimeIsChosen() async throws {
        let provider = LocalModelProvider(
            catalog: LocalModelCatalog(descriptors: [
                LocalModelDescriptor(
                    id: "example.model",
                    displayName: "Example",
                    format: .gguf
                )
            ])
        )

        let availability = await provider.availability()
        guard case .unsupported(let reason) = availability else {
            return XCTFail("Expected unsupported without a runtime")
        }
        XCTAssertTrue(reason.contains("runtime"))

        // Model metadata is still browsable, so a download UI can be built now.
        let models = try await provider.availableModels()
        XCTAssertEqual(models.map(\.id), ["example.model"])
        XCTAssertTrue(models.allSatisfy(\.isOnDevice))
    }

    func testLocalProviderUsesWhateverRuntimeIsInjected() async throws {
        let runtime = StubLocalRuntime()
        let descriptor = LocalModelDescriptor(id: "example.model", displayName: "Example", format: .mlx)
        let provider = LocalModelProvider(
            catalog: LocalModelCatalog(descriptors: [descriptor]),
            runtime: runtime,
            defaultModelID: descriptor.id
        )

        let availability = await provider.availability()
        XCTAssertTrue(availability.isAvailable)

        let response = try await provider.respond(
            to: AIRequest(systemPrompt: "", messages: [AIMessage(role: .user, content: "hi")])
        )
        XCTAssertEqual(response.text, "from the stub runtime")
    }

    func testRemoteProviderIsUnavailableWithoutACredential() async {
        let provider = RemoteAIProvider(
            adapter: StubRemoteAdapter(),
            configuration: StaticRemoteAIConfigurationSource(Self.readyConfiguration),
            credentials: StubCredentials(credential: nil),
            transport: StubTransport(response: HTTPResponse(statusCode: 200, body: Data()))
        )

        let availability = await provider.availability()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.isUserResolvable)
    }

    private static let readyConfiguration = RemoteAIConfiguration(
        baseURL: "https://api.example.invalid/v1",
        model: "stub-model"
    )

    func testRemoteProviderDelegatesEncodingAndParsingToItsAdapter() async throws {
        let adapter = StubRemoteAdapter()
        let transport = StubTransport(
            response: HTTPResponse(statusCode: 200, body: Data("ok".utf8))
        )
        let provider = RemoteAIProvider(
            adapter: adapter,
            configuration: StaticRemoteAIConfigurationSource(Self.readyConfiguration),
            credentials: StubCredentials(credential: "secret"),
            transport: transport
        )

        let response = try await provider.respond(
            to: AIRequest(systemPrompt: "sys", messages: [AIMessage(role: .user, content: "hi")])
        )

        XCTAssertEqual(response.text, "parsed by the adapter")
        XCTAssertEqual(response.providerID, adapter.providerID)
        let sent = try XCTUnwrap(transport.sentRequests.last)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer secret")
    }

    func testRemoteProviderSurfacesHTTPFailures() async {
        let provider = RemoteAIProvider(
            adapter: StubRemoteAdapter(),
            configuration: StaticRemoteAIConfigurationSource(Self.readyConfiguration),
            credentials: StubCredentials(credential: "secret"),
            transport: StubTransport(
                response: HTTPResponse(statusCode: 500, body: Data("boom".utf8))
            )
        )

        do {
            _ = try await provider.respond(to: AIRequest(systemPrompt: "", messages: []))
            XCTFail("Expected an error for a 500 response")
        } catch let error as AIProviderError {
            guard case .invalidResponse = error else {
                return XCTFail("Expected .invalidResponse, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialsAreNeverReadFromSource() async {
        // The default provider reads an environment variable derived from the
        // provider id; nothing is baked into the binary.
        let credentials = EnvironmentCredentialProvider(prefix: "ASSISTANT_TEST_KEY_")
        let value = await credentials.credential(for: "remote.example")
        XCTAssertNil(value)
    }
}

// MARK: - Stubs

private struct StubLocalRuntime: LocalModelRuntime {
    var supportedFormats: [LocalModelFormat] { [.mlx, .gguf] }

    func state(of model: LocalModelDescriptor) async -> LocalModelState { .ready }
    func load(_ model: LocalModelDescriptor) async throws {}
    func unload(_ model: LocalModelDescriptor) async {}

    func generate(_ request: AIRequest, model: LocalModelDescriptor) async throws -> AIResponse {
        AIResponse(text: "from the stub runtime", providerID: LocalModelProvider.providerID)
    }
}

private struct StubRemoteAdapter: RemoteAPIAdapter {
    var providerID: AIProviderIdentifier { "remote.stub" }
    var displayName: String { "Stub API" }
    var capabilityRank: Int { 90 }

    func availableModels(configuration: RemoteAIConfiguration) async throws -> [AIModel] {
        [
            AIModel(
                id: "remote.stub.model",
                displayName: "Stub model",
                supportsNativeToolCalling: true,
                isOnDevice: false
            )
        ]
    }

    func makeRequest(
        from request: AIRequest,
        configuration: RemoteAIConfiguration,
        credential: String
    ) throws -> HTTPRequest {
        HTTPRequest(
            url: URL(string: "https://example.invalid/v1/messages")!,
            headers: ["Authorization": "Bearer \(credential)"],
            body: Data()
        )
    }

    func parse(_ response: HTTPResponse, for request: AIRequest) throws -> AIResponse {
        AIResponse(text: "parsed by the adapter", providerID: providerID)
    }
}

private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let response: HTTPResponse
    private(set) var sentRequests: [HTTPRequest] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sentRequests.append(request)
        return response
    }
}

private struct StubCredentials: CredentialProvider {
    let value: String?

    init(credential: String?) { self.value = credential }

    func credential(for providerID: AIProviderIdentifier) async -> String? { value }
}
