import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
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

    /// The local provider's identity, which is written into the user's
    /// settings and must not drift.
    ///
    /// Part 10 replaced everything behind this provider — the runtime, the
    /// catalog, the download and verification pipeline — and changing the
    /// identifier along the way would have silently reset the provider choice
    /// of anyone who had selected it.
    func testLocalProviderKeepsItsIdentityAndNeedsNothingFromTheNetwork() async throws {
        let provider = LocalModelProvider(
            manager: LocalModelManager(
                catalog: LocalModelCatalog(),
                repository: SnapshotLocalModelRepository(store: EphemeralSnapshotStore()),
                settings: SnapshotSettingsRepository(store: EphemeralSnapshotStore()),
                store: LocalModelStore.temporary(),
                device: FixedDeviceResources.largePhone
            )
        )

        XCTAssertEqual(provider.metadata.id, "local.downloaded-model")
        XCTAssertEqual(provider.metadata.kind, .downloadedLocalModel)
        XCTAssertFalse(provider.metadata.requiresNetwork)
        XCTAssertFalse(provider.metadata.requiresCredentials)
        // Section 59: the engine may send tool results back and ask it to
        // carry on, which is what makes a multi-step local turn possible.
        XCTAssertTrue(provider.metadata.supportsToolResultContinuation)
    }

    /// A build with no inference runtime says so and refuses to answer — it
    /// never fabricates a reply, and it never reaches for the network instead
    /// (section 128).
    func testLocalProviderWithNoRuntimeRefusesRatherThanFabricating() async throws {
        let provider = LocalModelProvider(
            manager: LocalModelManager(
                catalog: LocalModelCatalog(),
                repository: SnapshotLocalModelRepository(store: EphemeralSnapshotStore()),
                settings: SnapshotSettingsRepository(store: EphemeralSnapshotStore()),
                store: LocalModelStore.temporary(),
                runtime: nil,
                device: FixedDeviceResources.largePhone
            ),
            runtime: nil
        )

        let availability = await provider.availability()
        guard case .unsupported(let reason) = availability else {
            return XCTFail("expected unsupported without a runtime, got \(availability)")
        }
        XCTAssertTrue(reason.contains("runtime"))

        do {
            _ = try await provider.respond(
                to: AIRequest(systemPrompt: "", messages: [AIMessage(role: .user, content: "hi")])
            )
            XCTFail("a provider with no runtime must throw, never return a fake answer")
        } catch let error as AIProviderError {
            guard case .unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        }
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
